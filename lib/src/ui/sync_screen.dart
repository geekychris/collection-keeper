import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/providers.dart';
import '../labels/label.dart' show qrModules;
import '../sync/sync_api.dart';
import '../sync/sync_controller.dart';

/// Servers people are likely to want, offered under the address field.
const _suggestions = [
  ('https://collections.hitorro.com', 'anywhere'),
  ('https://collections.hitorro.com:8443', 'home network'),
  ('http://192.168.1.219:31870', 'direct, home network'),
];

/// The home screen's sync button: shows the state and opens [SyncScreen].
class SyncButton extends ConsumerWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final (icon, tip) = switch (sync.status) {
          SyncStatus.off => (Icons.cloud_off_outlined, 'Sync server: not connected'),
          SyncStatus.syncing => (Icons.cloud_sync_outlined, 'Syncing…'),
          SyncStatus.idle when sync.pending > 0 => (Icons.cloud_upload_outlined, 'Sync: ${sync.pending} changes to send'),
          SyncStatus.idle => (Icons.cloud_done_outlined, 'Synced'),
          SyncStatus.error => (Icons.sync_problem_outlined, 'Sync: ${sync.error ?? 'failed'}'),
          SyncStatus.needsPairing => (Icons.sync_problem_outlined, 'Sync: connect again'),
        };
        return IconButton(
          tooltip: tip,
          icon: Icon(icon),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const SyncScreen()),
          ),
        );
      },
    );
  }
}

/// Choosing a sync server, pairing this device with it, and how syncing is going.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  late final TextEditingController _url, _deviceName;
  bool _busy = false;
  String? _problem;
  PairStart? _pairing;
  String? _pairingServer;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _url = TextEditingController(text: settings.serverUrl ?? '');
    _deviceName = TextEditingController(text: settings.deviceName ?? defaultDeviceName());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _url.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  /// The URL as typed, with https:// added when there's no scheme and no
  /// trailing slash. Null when it isn't a usable address.
  static String? normalise(String text) {
    var s = text.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    final uri = Uri.tryParse(s);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
    return s;
  }

  /// Plain http is fine on the home network, not across the internet.
  static bool insecure(String url) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http') return false;
    final h = uri.host;
    final local = h == 'localhost' ||
        h.endsWith('.local') ||
        !h.contains('.') ||
        RegExp(r'^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(h);
    return !local;
  }

  Future<void> _connect() async {
    final url = normalise(_url.text);
    if (url == null) {
      setState(() => _problem = 'Type the server\'s address, e.g. https://collections.example.com');
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final api = HttpSyncApi(url);
    try {
      final info = await api.info();
      if (info.apiVersion > 1) {
        throw const ServerError(200, 'The server is newer than this app; please update the app');
      }
      final settings = ref.read(settingsProvider)..deviceName = _deviceName.text.trim();
      final start = await api.pairStart(
        deviceName: settings.deviceName!.isEmpty ? defaultDeviceName() : settings.deviceName!,
        platform: Platform.operatingSystem,
        appVersion: '1.0.0',
      );
      setState(() {
        _pairing = start;
        _pairingServer = url;
      });
      unawaited(_openBrowser(start.verifyUrl));
      _schedulePoll(start);
    } catch (e) {
      setState(() => _problem = '$e');
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _schedulePoll(PairStart start) {
    final expires = DateTime.now().add(Duration(seconds: start.expiresIn));
    _poll?.cancel();
    _poll = Timer.periodic(Duration(seconds: start.interval.clamp(1, 30)), (timer) async {
      if (_pairing != start) return timer.cancel();
      final api = HttpSyncApi(_pairingServer!);
      try {
        final r = await api.pairPoll(start.deviceCode);
        if (!mounted || _pairing != start) return;
        switch (r.status) {
          case 'approved':
            timer.cancel();
            await ref.read(syncProvider).connect(_pairingServer!, r.token!, r.user!);
            if (mounted) setState(() => _pairing = null);
          case 'denied':
            timer.cancel();
            setState(() {
              _pairing = null;
              _problem = 'Connecting this device was refused in the browser.';
            });
          case 'expired':
            timer.cancel();
            setState(() {
              _pairing = null;
              _problem = 'The code expired. Connect again for a new one.';
            });
        }
      } on NetworkError {
        // Keep polling: the connection may come back before the code expires.
      } catch (e) {
        if (mounted) setState(() => _problem = '$e');
      } finally {
        api.close();
      }
      if (DateTime.now().isAfter(expires) && mounted && _pairing == start) {
        timer.cancel();
        setState(() {
          _pairing = null;
          _problem = 'The code expired. Connect again for a new one.';
        });
      }
    });
  }

  Future<void> _openBrowser(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // The QR code and the address on screen still work.
    }
  }

  void _cancelPairing() {
    _poll?.cancel();
    setState(() => _pairing = null);
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop syncing?'),
        content: const Text('This device keeps everything it has. Changes made here '
            'stay here until you connect again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok == true) ref.read(syncProvider).disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync server')),
      body: ListenableBuilder(
        listenable: sync,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_pairing != null)
              _PairingPanel(start: _pairing!, onOpen: _openBrowser, onCancel: _cancelPairing)
            else if (sync.connected && sync.status != SyncStatus.needsPairing)
              _ConnectedPanel(sync: sync, onDisconnect: _disconnect)
            else
              _chooseServer(sync),
          ],
        ),
      ),
    );
  }

  Widget _chooseServer(SyncController sync) {
    final theme = Theme.of(context);
    final url = normalise(_url.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        'Sync keeps your collections the same on all your devices, through a '
        'Collection Keeper server. Without one, everything stays on this device.',
        style: theme.textTheme.bodyMedium,
      ),
      if (sync.status == SyncStatus.needsPairing && sync.error != null) ...[
        const SizedBox(height: 12),
        Text(sync.error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Server address',
          hintText: 'https://collections.example.com',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _connect(),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final (u, note) in _suggestions)
          ActionChip(
            label: Text('${Uri.parse(u).authority} ($note)'),
            onPressed: () => setState(() => _url.text = u),
          ),
      ]),
      if (url != null && insecure(url)) ...[
        const SizedBox(height: 8),
        Text(
          'This address isn\'t encrypted (http). Use https outside your home network.',
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _deviceName,
        decoration: const InputDecoration(
          labelText: 'This device\'s name',
          helperText: 'Shown on the server\'s list of your devices',
        ),
      ),
      if (_problem != null) ...[
        const SizedBox(height: 16),
        Text(_problem!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _busy ? null : _connect,
        icon: _busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.link),
        label: const Text('Connect'),
      ),
      const SizedBox(height: 8),
      Text(
        'You\'ll approve this device in a browser where you\'re signed in to the server.',
        style: theme.textTheme.bodySmall,
      ),
    ]);
  }
}

String defaultDeviceName() {
  final os = switch (Platform.operatingSystem) {
    'ios' => 'iPhone or iPad',
    'macos' => 'Mac',
    'android' => 'Android',
    'windows' => 'Windows PC',
    final other => other,
  };
  final host = Platform.localHostname.split('.').first;
  return host.isEmpty || host == 'localhost' ? os : '$host ($os)';
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({required this.start, required this.onOpen, required this.onCancel});
  final PairStart start;
  final void Function(String url) onOpen;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Approve this device', style: theme.textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Sign in to the server in your browser and check it shows this code:'),
      const SizedBox(height: 16),
      Center(
        child: SelectableText(
          start.userCode,
          style: theme.textTheme.displaySmall?.copyWith(
            fontFamily: 'monospace',
            letterSpacing: 4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => onOpen(start.verifyUrl),
        icon: const Icon(Icons.open_in_browser),
        label: const Text('Open in browser'),
      ),
      const SizedBox(height: 24),
      const Text('Or scan this with a phone that\'s signed in:'),
      const SizedBox(height: 12),
      Center(
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: SizedBox.square(dimension: 200, child: QrCodeView(data: start.verifyUrl)),
        ),
      ),
      const SizedBox(height: 8),
      Center(child: SelectableText(start.verifyUrl, style: theme.textTheme.bodySmall)),
      const SizedBox(height: 24),
      const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Waiting for approval…'),
      ]),
      const SizedBox(height: 16),
      TextButton(onPressed: onCancel, child: const Text('Cancel')),
    ]);
  }
}

class _ConnectedPanel extends StatelessWidget {
  const _ConnectedPanel({required this.sync, required this.onDisconnect});
  final SyncController sync;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = sync.settings;
    final last = sync.lastSyncAt == 0
        ? 'not yet'
        : DateFormat.yMMMd().add_Hm().format(DateTime.fromMillisecondsSinceEpoch(sync.lastSyncAt));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.account_circle_outlined),
        title: Text(settings.syncUserName ?? ''),
        subtitle: Text(settings.serverUrl ?? ''),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(sync.status == SyncStatus.error ? Icons.sync_problem_outlined : Icons.cloud_done_outlined),
        title: Text(switch (sync.status) {
          SyncStatus.syncing => 'Syncing…',
          SyncStatus.error => 'Last attempt failed; trying again shortly',
          _ => 'Last synced $last',
        }),
        subtitle: Text(sync.pending == 0
            ? 'Nothing waiting to be sent'
            : sync.pending == 1
                ? '1 change waiting to be sent'
                : '${sync.pending} changes waiting to be sent'),
      ),
      if (sync.status == SyncStatus.error && sync.error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(sync.error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      if (sync.lastResult != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('Last sync: ${sync.lastResult}', style: theme.textTheme.bodySmall),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: sync.status == SyncStatus.syncing ? null : sync.syncNow,
        icon: const Icon(Icons.sync),
        label: const Text('Sync now'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: onDisconnect,
        icon: const Icon(Icons.link_off),
        label: const Text('Disconnect'),
      ),
    ]);
  }
}

/// A QR code drawn with whole modules and a quiet zone, black on white.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data});
  final String data;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _QrPainter(qrModules(data)));
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.modules);
  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final n = modules.length + 2; // one module of quiet zone each side
    final m = size.shortestSide / n;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final black = Paint()..color = Colors.black;
    for (var r = 0; r < modules.length; r++) {
      for (var c = 0; c < modules.length; c++) {
        if (modules[r][c]) canvas.drawRect(Rect.fromLTWH((c + 1) * m, (r + 1) * m, m + 0.3, m + 0.3), black);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.modules != modules;
}
