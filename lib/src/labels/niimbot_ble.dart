import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'niimbot.dart';
import 'niimbot_session.dart';

/// The service NIIMBOT printers offer; the channel is a characteristic in a
/// vendor service that both notifies and takes writes without response.
const niimbotService = 'e7810a71-73ae-499d-8c15-faa9aef0c3f2';

/// A printer seen nearby.
class NearbyPrinter {
  const NearbyPrinter({required this.id, required this.name, required this.rssi, this.model});
  final String id;
  final String name;
  final int rssi;
  final NiimbotModel? model;
}

/// Bluetooth LE link to a connected printer.
class BleLink implements NiimbotLink {
  BleLink._(this.deviceId, this._service, this._char, this._chunk);

  final String deviceId;
  final String _service, _char;
  final int _chunk;

  /// Connects to [deviceId], finds the printer's channel and subscribes to it.
  static Future<BleLink> connect(String deviceId) async {
    await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 15));
    try {
      final services = await UniversalBle.discoverServices(deviceId);
      // Only the long (vendor) services hold the channel.
      for (final s in services.where((s) => !_isStandard(s.uuid))) {
        for (final c in s.characteristics) {
          if (c.properties.contains(CharacteristicProperty.notify) &&
              c.properties.contains(CharacteristicProperty.writeWithoutResponse)) {
            var mtu = 23;
            try {
              mtu = await UniversalBle.requestMtu(deviceId, 247);
            } catch (_) {
              // keep the minimum
            }
            await UniversalBle.subscribeNotifications(deviceId, s.uuid, c.uuid);
            return BleLink._(deviceId, s.uuid, c.uuid, math.max(20, mtu - 3));
          }
        }
      }
      throw const NiimbotError("This doesn't look like a NIIMBOT printer: its data channel wasn't found.");
    } catch (_) {
      await UniversalBle.disconnect(deviceId);
      rethrow;
    }
  }

  static bool _isStandard(String uuid) => uuid.toLowerCase().endsWith('-0000-1000-8000-00805f9b34fb');

  @override
  Stream<Uint8List> get incoming =>
      UniversalBle.characteristicValueStream(deviceId, _char, serviceId: _service);

  @override
  Future<void> write(Uint8List bytes) async {
    for (var i = 0; i < bytes.length; i += _chunk) {
      await UniversalBle.write(deviceId, _service, _char,
          Uint8List.sublistView(bytes, i, math.min(bytes.length, i + _chunk)),
          withoutResponse: true);
    }
  }

  @override
  Future<void> close() => UniversalBle.disconnect(deviceId);
}

enum PrinterState { idle, scanning, connecting, connected, printing }

/// The app's one label printer: finding it, connecting, and printing. The UI
/// listens to it.
class PrinterController extends ChangeNotifier {
  PrinterState state = PrinterState.idle;
  final List<NearbyPrinter> nearby = [];
  NiimbotSession? session;
  String? deviceId;
  String? error;
  (int done, int total)? progress;

  StreamSubscription<BleDevice>? _scan;

  PrinterInfo? get info => session?.info;
  bool get connected => session != null;

  Future<void> startScan() async {
    error = null;
    nearby.clear();
    state = PrinterState.scanning;
    notifyListeners();
    try {
      try {
        await UniversalBle.requestPermissions();
      } catch (_) {
        // reported through the availability state below
      }
      var availability = await UniversalBle.getBluetoothAvailabilityState();
      // Just after permission is granted the state can still be settling.
      for (var i = 0;
          i < 10 && (availability == AvailabilityState.unknown || availability == AvailabilityState.resetting);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        availability = await UniversalBle.getBluetoothAvailabilityState();
      }
      if (availability != AvailabilityState.poweredOn) {
        throw NiimbotError(switch (availability) {
          AvailabilityState.poweredOff => 'Bluetooth is off. Turn it on to find the printer.',
          AvailabilityState.unauthorized => 'Collection Keeper isn’t allowed to use Bluetooth. '
              'Allow it in Settings.',
          AvailabilityState.unsupported => 'This device has no Bluetooth LE.',
          _ => 'Bluetooth isn’t ready yet. Try again in a moment.',
        });
      }
      await _scan?.cancel();
      _scan = UniversalBle.scanStream.listen(_onDevice);
      await UniversalBle.startScan();
      Timer(const Duration(seconds: 12), () {
        if (state == PrinterState.scanning) stopScan();
      });
    } catch (e) {
      error = '$e';
      state = connected ? PrinterState.connected : PrinterState.idle;
      notifyListeners();
    }
  }

  void _onDevice(BleDevice d) {
    final name = d.name ?? '';
    final model = NiimbotModel.fromDeviceName(name);
    if (model == null && !d.services.contains(niimbotService)) return;
    nearby
      ..removeWhere((p) => p.id == d.deviceId)
      ..add(NearbyPrinter(
          id: d.deviceId, name: name.isEmpty ? 'NIIMBOT printer' : name, rssi: d.rssi ?? -100, model: model))
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    notifyListeners();
  }

  Future<void> stopScan() async {
    await _scan?.cancel();
    _scan = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    if (state == PrinterState.scanning) {
      state = connected ? PrinterState.connected : PrinterState.idle;
      notifyListeners();
    }
  }

  /// Connects to a printer seen in a scan, or to one connected to before.
  Future<bool> connect(String id, String name) async {
    await stopScan();
    await disconnect();
    error = null;
    state = PrinterState.connecting;
    notifyListeners();
    try {
      final link = await BleLink.connect(id);
      final s = NiimbotSession(link);
      try {
        await s.handshake(name);
      } catch (_) {
        await s.close();
        rethrow;
      }
      session = s;
      deviceId = id;
      state = PrinterState.connected;
      notifyListeners();
      return true;
    } catch (e) {
      error = e is NiimbotError
          ? e.message
          : 'Couldn’t connect: $e. Is the printer on, and not connected to the NIIMBOT app?';
      state = PrinterState.idle;
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect() async {
    final s = session;
    session = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
    if (state == PrinterState.connected) state = PrinterState.idle;
    notifyListeners();
  }

  Future<void> print(List<Bitmap1> labels, {int copies = 1, int? density}) async {
    final s = session;
    if (s == null) throw const NiimbotError('Connect a printer first.');
    state = PrinterState.printing;
    progress = (0, labels.length * copies);
    notifyListeners();
    try {
      await s.printLabels(labels, copies: copies, density: density, progress: (done, total) {
        progress = (done, total);
        notifyListeners();
      });
    } finally {
      progress = null;
      state = session == null ? PrinterState.idle : PrinterState.connected;
      notifyListeners();
    }
  }
}
