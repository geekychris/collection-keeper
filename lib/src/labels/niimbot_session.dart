import 'dart:async';
import 'dart:typed_data';

import 'label.dart';
import 'niimbot.dart';

/// A byte channel to a printer (Bluetooth in the app, a fake in tests).
abstract class NiimbotLink {
  /// Bytes as they arrive (one notification each).
  Stream<Uint8List> get incoming;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

/// What the printer said about itself and what's loaded.
class PrinterInfo {
  PrinterInfo(this.deviceName);
  final String deviceName;
  int? modelId;
  NiimbotModel? model;
  int protocolVersion = 0;
  HeadInfo? head;
  int? battery;
  NiimbotLabelType? labelType;
  RollRfid? rfid;
  PaperInfo? paper;

  /// The model, or a stand-in built from what the printer reported.
  NiimbotModel get effectiveModel {
    if (model != null) return model!;
    final h = head;
    if (h == null) return NiimbotModel.fallback.copyWith(name: deviceName);
    return NiimbotModel.fallback.copyWith(
      name: deviceName,
      printheadPixels: h.printheadWidth,
      dpi: h.resolutionClass == 3 ? 300 : 203,
      direction: h.printheadWidth > 200 ? NiimbotDirection.top : NiimbotDirection.left,
    );
  }

  /// The roll's size, when the printer can tell.
  LabelSize? get rollSize => paper == null ? null : LabelSize.fromPaper(paper!, effectiveModel);

  NiimbotPrintTask get printTask => effectiveModel.printTask(protocolVersion);
}

/// A connected printer: one request at a time, each waiting for its reply.
class NiimbotSession {
  NiimbotSession(this.link, {this.packetGap = const Duration(milliseconds: 10)}) {
    _sub = link.incoming.listen(_receive);
  }

  final NiimbotLink link;

  /// niimbluelib's packet interval: some printers drop packets sent back to back.
  final Duration packetGap;

  late final StreamSubscription<Uint8List> _sub;
  final _buffer = <int>[];
  final _waiters = <({List<int> ids, Completer<NiimbotPacket> c})>[];
  final _inbox = <NiimbotPacket>[];
  Future<void> _tail = Future.value();
  int? _pageIndex;
  PrinterInfo? info;

  Future<void> close() async {
    await _sub.cancel();
    await link.close();
  }

  /// Runs [body] after every earlier request has finished.
  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Sends a packet and waits for its reply (one-way packets just go). A
  /// PrintError reply throws.
  Future<NiimbotPacket?> send(NiimbotPacket p, {Duration timeout = const Duration(seconds: 1)}) =>
      _locked(() => _exchange(p, timeout));

  Future<NiimbotPacket?> _exchange(NiimbotPacket p, Duration timeout) async {
    _inbox.clear();
    if (packetGap > Duration.zero) await Future<void>.delayed(packetGap);
    await link.write(p.bytes);
    if (p.oneWay) return null;
    return _reply(p.replies, timeout);
  }

  bool _matches(NiimbotPacket p, List<int> ids) =>
      ids.isEmpty ||
      ids.contains(p.command) ||
      p.command == NiimbotCommand.inPrintError ||
      p.command == NiimbotCommand.inNotSupported;

  Future<NiimbotPacket> _reply(List<int> ids, Duration timeout) async {
    final i = _inbox.indexWhere((p) => _matches(p, ids));
    late NiimbotPacket p;
    if (i >= 0) {
      p = _inbox.removeAt(i);
    } else {
      final waiter = (ids: ids, c: Completer<NiimbotPacket>());
      _waiters.add(waiter);
      try {
        p = await waiter.c.future.timeout(timeout);
      } on TimeoutException {
        _waiters.remove(waiter);
        throw const NiimbotError("The printer didn't reply in time.");
      }
    }
    final error = NiimbotReplies.error(p);
    if (error != null) throw error;
    return p;
  }

  void _receive(Uint8List bytes) {
    _buffer.addAll(bytes);
    final (:packets, :rest) = NiimbotPacket.split(_buffer);
    _buffer
      ..clear()
      ..addAll(rest);
    for (final p in packets) {
      if (p.command == NiimbotCommand.inPrinterPageIndex && p.data.length == 2) {
        _pageIndex = p.data[0] << 8 | p.data[1];
      }
      final w = _waiters.indexWhere((w) => _matches(p, w.ids));
      if (w >= 0) {
        _waiters.removeAt(w).c.complete(p);
      } else {
        _inbox.add(p);
        if (_inbox.length > 32) _inbox.removeAt(0);
      }
    }
  }

  /// A request whose failure doesn't matter (not every printer answers everything).
  Future<NiimbotPacket?> _ask(NiimbotPacket p, {Duration timeout = const Duration(seconds: 1)}) async {
    try {
      return await send(p, timeout: timeout);
    } on NiimbotError {
      return null;
    }
  }

  /// Agrees the protocol and reads what the printer is and what's loaded.
  Future<PrinterInfo> handshake(String deviceName) async {
    final i = PrinterInfo(deviceName);
    final c = await send(NiimbotPackets.connect(), timeout: const Duration(seconds: 3));
    if (c == null) throw const NiimbotError('No reply to Connect.');
    switch (NiimbotReplies.connectResult(c)) {
      case 3:
        final s = await _ask(NiimbotPackets.printerStatusData());
        i.protocolVersion = s == null ? 0 : NiimbotReplies.protocolVersion(s);
      case 2:
        i.protocolVersion = 1;
      case 0:
        throw const NiimbotError('The printer refused the connection.');
    }
    final idReply = await _ask(NiimbotPackets.info(NiimbotInfo.modelId));
    final id = idReply == null ? null : NiimbotReplies.modelId(idReply);
    if (id != null) {
      i.modelId = id;
      i.model = NiimbotModel.byId(id);
    }
    i.model ??= NiimbotModel.fromDeviceName(deviceName);
    final head = await _ask(NiimbotPackets.heartbeat(3));
    i.head = head == null ? null : NiimbotReplies.headInfo(head);
    final battery = await _ask(NiimbotPackets.info(NiimbotInfo.battery));
    i.battery = battery == null ? null : NiimbotReplies.battery(battery);
    final type = await _ask(NiimbotPackets.info(NiimbotInfo.labelType));
    final typeCode = type == null ? null : NiimbotReplies.byte(type);
    i.labelType = typeCode == null ? null : NiimbotLabelType.fromCode(typeCode);
    info = i;
    await refreshRoll();
    return i;
  }

  /// Reads the roll's RFID tag and, on printers that know it, its size.
  Future<void> refreshRoll() async {
    final i = info;
    if (i == null) return;
    final rfid = await _ask(NiimbotPackets.rfidInfo());
    i.rfid = rfid == null ? null : NiimbotReplies.rfid(rfid);
    final paper = await _ask(NiimbotPackets.paperInfo());
    // The B21 Pro's paper height includes the gap.
    i.paper = paper == null ? null : NiimbotReplies.paper(paper, heightIncludesGap: i.modelId == 785);
  }

  /// Carries out a print job's steps. [progress] gets pages done of [total].
  Future<void> run(List<NiimbotStep> steps, {required int total, void Function(int done, int total)? progress}) =>
      _locked(() async {
        _pageIndex = null;
        try {
          for (final step in steps) {
            switch (step) {
              case SendStep(:final packet):
                await _exchange(packet, const Duration(seconds: 10));
              case SendUntilTrueStep(:final packet, :final attempts):
                var ok = false;
                for (var a = 0; a < attempts && !ok; a++) {
                  try {
                    final r = await _exchange(packet, const Duration(seconds: 2));
                    ok = r != null && NiimbotReplies.isTrue(r);
                  } on NiimbotError {
                    // try again
                  }
                  if (!ok) await Future<void>.delayed(const Duration(milliseconds: 500));
                }
                if (!ok) throw const NiimbotError("The printer didn't accept the page.");
              case WaitStatusStep(:final pages):
                await _waitStatus(pages, total, progress);
              case WaitPageIndexStep(:final pages):
                var last = DateTime.now();
                while ((_pageIndex ?? 0) < pages) {
                  final before = _pageIndex;
                  await Future<void>.delayed(const Duration(milliseconds: 200));
                  if (_pageIndex != before) {
                    last = DateTime.now();
                    progress?.call(_pageIndex ?? 0, total);
                  }
                  if (DateTime.now().difference(last) > const Duration(seconds: 8)) {
                    throw const NiimbotError('The printer stopped reporting pages.');
                  }
                }
              case WaitPrintEndStep():
                final start = DateTime.now();
                while (true) {
                  try {
                    final r = await _exchange(NiimbotPackets.printEnd(), const Duration(seconds: 2));
                    if (r != null && NiimbotReplies.isTrue(r)) break;
                  } on NiimbotError {
                    // still printing
                  }
                  if (DateTime.now().difference(start) > const Duration(seconds: 60)) {
                    throw const NiimbotError("The printer didn't finish.");
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 500));
                }
              case EndStep():
                try {
                  await _exchange(NiimbotPackets.printEnd(), const Duration(seconds: 2));
                } on NiimbotError {
                  // finished anyway
                }
            }
          }
          progress?.call(total, total);
        } catch (_) {
          try {
            await _exchange(NiimbotPackets.printEnd(), const Duration(seconds: 2));
          } catch (_) {}
          rethrow;
        }
      });

  Future<void> _waitStatus(int pages, int total, void Function(int, int)? progress) async {
    var lastChange = DateTime.now();
    (int, int, int)? last;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      PrintStatus? status;
      for (var a = 0; a < 2 && status == null; a++) {
        final r = await _exchange(NiimbotPackets.printStatus(), const Duration(seconds: 5));
        if (r != null) status = NiimbotReplies.printStatus(r);
      }
      if (status == null) continue;
      if (status.error != 0) {
        throw NiimbotError('The printer reported: ${NiimbotReplies.errorName(status.error)}.',
            code: status.error);
      }
      progress?.call(status.page, total);
      if (status.page >= pages) return;
      final now = (status.page, status.printProgress, status.feedProgress);
      if (now != last) {
        last = now;
        lastChange = DateTime.now();
      }
      if (DateTime.now().difference(lastChange) > const Duration(seconds: 20)) {
        throw const NiimbotError('The printer stopped part-way. Check the labels and the lid.');
      }
    }
  }

  /// Prints [labels] (1-bit pictures as read) on the connected printer.
  Future<void> printLabels(List<Bitmap1> labels,
      {int copies = 1, int? density, void Function(int done, int total)? progress}) async {
    final i = info;
    if (i == null) throw const NiimbotError('The printer isn’t connected.');
    final model = i.effectiveModel;
    final pages = [for (final b in labels) NiimbotPage(NiimbotImage(b, model.direction), copies)];
    final type = i.labelType == null || i.labelType == NiimbotLabelType.invalid
        ? NiimbotLabelType.withGaps
        : i.labelType!;
    final steps = NiimbotJob.steps(
      task: i.printTask,
      pages: pages,
      density: (density ?? model.densityDefault).clamp(model.densityMin, model.densityMax),
      labelType: type,
      printhead: model.printheadPixels,
    );
    await run(steps, total: pages.fold(0, (n, p) => n + p.copies), progress: progress);
  }
}
