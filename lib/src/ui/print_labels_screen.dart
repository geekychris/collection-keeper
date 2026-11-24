import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:printing/printing.dart';

import '../app/providers.dart';
import '../labels/label.dart';
import '../labels/niimbot_session.dart';
import '../labels/niimbot_ble.dart';
import '../labels/pdf_labels.dart';
import 'common.dart';

enum _Output { niimbot, pdf }

/// Prints labels with QR codes: on a NIIMBOT printer over Bluetooth, or as a
/// PDF for any other printer (one label per page, or a sheet of them).
class PrintLabelsScreen extends ConsumerStatefulWidget {
  const PrintLabelsScreen({super.key, required this.labels});
  final List<LabelContent> labels;

  @override
  ConsumerState<PrintLabelsScreen> createState() => _PrintLabelsScreenState();
}

class _PrintLabelsScreenState extends ConsumerState<PrintLabelsScreen> {
  late _Output _output = ref.read(settingsProvider).printerId != null ? _Output.niimbot : _Output.pdf;
  late LabelSize? _size = LabelSize.named(ref.read(settingsProvider).labelSizeId ?? '');
  late PdfLabelLayout _layout = ref.read(settingsProvider).pdfLayout;
  late int? _density = ref.read(settingsProvider).density;
  int _copies = 1;
  int _preview = 0;

  PrinterController get _printer => ref.read(printerProvider);

  /// The size to print: the roll the printer reports, else the one chosen,
  /// else the usual one for the model.
  LabelSize _effectiveSize(PrinterInfo? info) {
    if (_output == _Output.niimbot) {
      final roll = info?.rollSize;
      if (roll != null) return roll;
      final model = info?.effectiveModel;
      if (_size != null && (model == null || _size!.fits(model))) return _size!;
      return model == null ? LabelSize.named('30x12')! : LabelSize.usual(model);
    }
    return _size ?? LabelSize.named('40x30')!;
  }

  Future<void> _connectSaved() async {
    final s = ref.read(settingsProvider);
    if (s.printerId == null) return;
    await _printer.connect(s.printerId!, s.printerName ?? 'NIIMBOT printer');
  }

  Future<void> _connect(NearbyPrinter p) async {
    if (await _printer.connect(p.id, p.name)) {
      ref.read(settingsProvider)
        ..printerId = p.id
        ..printerName = p.name;
    }
  }

  Future<void> _printNiimbot() async {
    final info = _printer.info;
    if (info == null) return;
    final model = info.effectiveModel;
    final size = _effectiveSize(info);
    final canvas = size.canvas(model);
    try {
      final bitmaps = [
        for (final l in widget.labels) await renderLabel(l, w: canvas.w, h: canvas.h, dpi: model.dpi),
      ];
      await _printer.print(bitmaps, copies: _copies, density: _density);
      if (mounted) {
        final n = widget.labels.length * _copies;
        showMessage(context, n == 1 ? 'Printed 1 label' : 'Printed $n labels');
      }
    } catch (e) {
      if (mounted) showMessage(context, '$e');
    }
  }

  Future<void> _printPdf({required bool share}) async {
    final size = _effectiveSize(null);
    ref.read(settingsProvider)
      ..labelSizeId = size.id
      ..pdfLayout = _layout;
    final labels = [for (final l in widget.labels) for (var i = 0; i < _copies; i++) l];
    final bytes = await labelsPdf(labels, size, _layout);
    if (share) {
      await Printing.sharePdf(bytes: bytes, filename: 'labels.pdf');
    } else {
      await Printing.layoutPdf(onLayout: (_) => bytes, name: 'Labels', dynamicLayout: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.labels.length;
    return Scaffold(
      appBar: AppBar(title: Text(n == 1 ? 'Print label' : 'Print $n labels')),
      body: ListenableBuilder(
        listenable: _printer,
        builder: (context, _) {
          final info = _printer.info;
          final size = _effectiveSize(info);
          final model = _output == _Output.niimbot ? info?.effectiveModel : null;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            Center(
              child: SegmentedButton<_Output>(
                segments: const [
                  ButtonSegment(
                      value: _Output.niimbot, icon: Icon(Icons.bluetooth), label: Text('NIIMBOT')),
                  ButtonSegment(
                      value: _Output.pdf, icon: Icon(Icons.print_outlined), label: Text('Other printer')),
                ],
                selected: {_output},
                onSelectionChanged: (s) => setState(() => _output = s.first),
              ),
            ),
            const SizedBox(height: 16),
            _LabelPreview(
              content: widget.labels[_preview.clamp(0, n - 1)],
              size: size,
              dpi: model?.dpi ?? 203,
              clipWidth: model == null ? null : size.canvas(model),
            ),
            if (n > 1)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _preview > 0 ? () => setState(() => _preview--) : null,
                ),
                Text('${_preview + 1} of $n'),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _preview < n - 1 ? () => setState(() => _preview++) : null,
                ),
              ]),
            const SizedBox(height: 8),
            if (_output == _Output.niimbot) ..._niimbotControls(info, size) else ..._pdfControls(size),
          ]);
        },
      ),
    );
  }

  Widget _copiesRow() => Row(children: [
        const Text('Copies of each'),
        const Spacer(),
        IconButton(
            onPressed: _copies > 1 ? () => setState(() => _copies--) : null, icon: const Icon(Icons.remove)),
        Text('$_copies'),
        IconButton(
            onPressed: _copies < 20 ? () => setState(() => _copies++) : null, icon: const Icon(Icons.add)),
      ]);

  List<Widget> _niimbotControls(PrinterInfo? info, LabelSize size) {
    final p = _printer;
    final saved = ref.read(settingsProvider);
    final busy = p.state == PrinterState.connecting || p.state == PrinterState.printing;
    if (info == null) {
      return [
        if (p.error != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(padding: const EdgeInsets.all(12), child: Text(p.error!)),
          ),
        if (saved.printerId != null)
          ListTile(
            leading: const Icon(Icons.print_outlined),
            title: Text(saved.printerName ?? 'NIIMBOT printer'),
            subtitle: const Text('Used last time'),
            trailing: FilledButton(
              onPressed: busy ? null : _connectSaved,
              child: const Text('Connect'),
            ),
          ),
        ListTile(
          leading: p.state == PrinterState.scanning
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.bluetooth_searching),
          title: Text(p.state == PrinterState.scanning ? 'Looking for printers…' : 'Find a printer nearby'),
          subtitle: const Text('Turn the printer on, and close the NIIMBOT app if it is connected.'),
          onTap: busy || p.state == PrinterState.scanning ? null : p.startScan,
        ),
        for (final d in p.nearby)
          ListTile(
            leading: const Icon(Icons.print),
            title: Text(d.name),
            subtitle: Text([?d.model?.displayName, 'signal ${d.rssi} dBm'].join(' · ')),
            trailing: p.state == PrinterState.connecting
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: busy ? null : () => _connect(d),
          ),
      ];
    }

    final model = info.effectiveModel;
    final roll = info.rollSize;
    final fitting = LabelSize.all.where((s) => s.fits(model)).toList();
    return [
      ListTile(
        leading: const Icon(Icons.print),
        title: Text('${model.displayName} connected'),
        subtitle: Text([
          if (info.battery != null) 'battery ${info.battery}%',
          if (info.rfid?.remaining != null) '${info.rfid!.remaining} labels left',
        ].join(' · ')),
        trailing: TextButton(onPressed: busy ? null : p.disconnect, child: const Text('Disconnect')),
      ),
      if (roll != null)
        ListTile(
          leading: const Icon(Icons.straighten),
          title: Text('Labels: ${roll.name}'),
          subtitle: const Text('As the printer reports the roll'),
        )
      else
        DropdownButtonFormField<String>(
          initialValue: fitting.any((s) => s.id == size.id) ? size.id : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Label size'),
          items: [for (final s in fitting) DropdownMenuItem(value: s.id, child: Text(s.name))],
          onChanged: (id) {
            setState(() => _size = LabelSize.named(id ?? ''));
            ref.read(settingsProvider).labelSizeId = id;
          },
        ),
      const SizedBox(height: 8),
      Row(children: [
        const Text('Darkness'),
        Expanded(
          child: Slider(
            min: model.densityMin.toDouble(),
            max: model.densityMax.toDouble(),
            divisions: (model.densityMax - model.densityMin).clamp(1, 20),
            value: (_density ?? model.densityDefault).clamp(model.densityMin, model.densityMax).toDouble(),
            label: '${_density ?? model.densityDefault}',
            onChanged: (v) {
              setState(() => _density = v.round());
              ref.read(settingsProvider).density = v.round();
            },
          ),
        ),
      ]),
      _copiesRow(),
      const SizedBox(height: 12),
      if (p.state == PrinterState.printing)
        Column(children: [
          LinearProgressIndicator(
            value: p.progress == null || p.progress!.$2 == 0 ? null : p.progress!.$1 / p.progress!.$2,
          ),
          const SizedBox(height: 8),
          Text('Printing ${p.progress?.$1 ?? 0} of ${p.progress?.$2 ?? 0}…'),
        ])
      else
        FilledButton.icon(
          onPressed: busy ? null : _printNiimbot,
          icon: const Icon(Icons.print),
          label: Text(widget.labels.length * _copies == 1
              ? 'Print'
              : 'Print ${widget.labels.length * _copies} labels'),
        ),
    ];
  }

  List<Widget> _pdfControls(LabelSize size) => [
        DropdownButtonFormField<String>(
          initialValue: size.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Label size'),
          items: [for (final s in LabelSize.all) DropdownMenuItem(value: s.id, child: Text(s.name))],
          onChanged: (id) => setState(() => _size = LabelSize.named(id ?? '') ?? _size),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<PdfLabelLayout>(
          initialValue: _layout,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Layout'),
          items: [for (final l in PdfLabelLayout.values) DropdownMenuItem(value: l, child: Text(l.label))],
          onChanged: (l) => setState(() => _layout = l ?? _layout),
        ),
        const SizedBox(height: 8),
        _copiesRow(),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: [
          FilledButton.icon(
            onPressed: () => _printPdf(share: false),
            icon: const Icon(Icons.print),
            label: const Text('Print…'),
          ),
          OutlinedButton.icon(
            onPressed: () => _printPdf(share: true),
            icon: const Icon(Icons.ios_share),
            label: const Text('Share PDF'),
          ),
        ]),
      ];
}

/// The label as it will print, drawn in 1-bit at the printer's resolution.
class _LabelPreview extends StatefulWidget {
  const _LabelPreview({required this.content, required this.size, required this.dpi, this.clipWidth});
  final LabelContent content;
  final LabelSize size;
  final int dpi;
  final ({int w, int h, bool clipped})? clipWidth;

  @override
  State<_LabelPreview> createState() => _LabelPreviewState();
}

class _LabelPreviewState extends State<_LabelPreview> {
  Future<ui.Image>? _image;
  String? _key;

  void _render() {
    final key = '${widget.content.code}|${widget.content.title}|${widget.size.id}|'
        '${widget.size.w}x${widget.size.h}|${widget.dpi}|${widget.clipWidth}';
    if (key == _key) return;
    _key = key;
    final w = widget.clipWidth?.w ?? (widget.size.w * widget.dpi / 25.4).round();
    final h = widget.clipWidth?.h ?? (widget.size.h * widget.dpi / 25.4).round();
    _image = renderLabel(widget.content, w: w, h: h, dpi: widget.dpi).then(bitmapToImage);
  }

  @override
  Widget build(BuildContext context) {
    _render();
    return Column(children: [
      Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 240),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
          ),
          child: AspectRatio(
            aspectRatio: widget.size.w / widget.size.h,
            child: FutureBuilder<ui.Image>(
              future: _image,
              builder: (context, snap) => snap.hasData
                  ? RawImage(image: snap.data, fit: BoxFit.contain, filterQuality: FilterQuality.none)
                  : const SizedBox(),
            ),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        widget.size.name + (widget.clipWidth?.clipped == true ? ' (wider than the print head: clipped)' : ''),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }
}
