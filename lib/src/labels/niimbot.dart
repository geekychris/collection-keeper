// NIIMBOT label printer protocol: packets, replies, the printer models and how
// each one prints. Pure Dart, so it is tested without a printer.
//
// Ported from parts-inventory-apple's PartsKit/Niimbot.swift, itself a port of
// NiimBlue's niimbluelib (MIT, © 2024 MultiMote, github.com/MultiMote/niimbluelib):
// packets, commands, packet generator and parser, print tasks, image encoder
// and printer models. Only what's needed to read a printer and print
// single-colour labels.

import 'dart:typed_data';

// ----------------------------------------------------------------- packets

class PacketParseError implements Exception {
  const PacketParseError(this.reason);
  final String reason;
  @override
  String toString() => 'Bad NIIMBOT packet: $reason';
}

/// One packet: `55 55 cmd len data… xor aa aa` (Connect is sent with a
/// leading `03`).
class NiimbotPacket {
  NiimbotPacket(this.command, [List<int> data = const [1], List<int>? replies])
      : data = List.unmodifiable(data),
        replies = List.unmodifiable(replies ?? NiimbotCommand.replies[command] ?? const []);

  final int command;
  final List<int> data;

  /// Reply ids this request waits for; empty for a one-way packet.
  final List<int> replies;

  bool get oneWay => replies.isEmpty;

  int get checksum => data.fold(command ^ (data.length & 0xFF), (a, b) => a ^ b);

  Uint8List get bytes {
    final raw = [0x55, 0x55, command, data.length & 0xFF, ...data, checksum, 0xAA, 0xAA];
    return Uint8List.fromList(command == NiimbotCommand.connect ? [0x03, ...raw] : raw);
  }

  /// The same packet, not waiting for a reply.
  NiimbotPacket get oneWayCopy => NiimbotPacket(command, data, const []);

  @override
  bool operator ==(Object other) =>
      other is NiimbotPacket &&
      other.command == command &&
      _listEq(other.data, data) &&
      _listEq(other.replies, replies);

  @override
  int get hashCode => Object.hash(command, Object.hashAll(data), Object.hashAll(replies));

  @override
  String toString() => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  /// One whole packet.
  static NiimbotPacket parse(List<int> b) {
    if (b.length < 7) throw const PacketParseError('too short');
    if (b[0] != 0x55 || b[1] != 0x55) throw const PacketParseError('bad head');
    final len = b[3];
    if (b.length != 7 + len) throw const PacketParseError('bad size');
    if (b[b.length - 2] != 0xAA || b[b.length - 1] != 0xAA) {
      throw const PacketParseError('bad tail');
    }
    final p = NiimbotPacket(b[2], b.sublist(4, 4 + len), const []);
    if (p.checksum != b[4 + len]) throw const PacketParseError('bad checksum');
    return p;
  }

  /// Splits notification bytes into packets. Returns the whole packets and the
  /// bytes still waiting for more (a reply can span notifications). Rubbish
  /// that can't start a packet is dropped.
  static ({List<NiimbotPacket> packets, List<int> rest}) split(List<int> buffer) {
    final out = <NiimbotPacket>[];
    var i = 0;
    while (i < buffer.length) {
      if (buffer[i] != 0x55) return (packets: out, rest: const []);
      if (buffer.length - i < 4) break;
      if (buffer[i + 1] != 0x55) return (packets: out, rest: const []);
      final total = 7 + buffer[i + 3];
      if (buffer.length - i < total) break;
      try {
        out.add(parse(buffer.sublist(i, i + total)));
      } on PacketParseError {
        return (packets: out, rest: const []);
      }
      i += total;
    }
    return (packets: out, rest: buffer.sublist(i));
  }
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Command ids: requests to the printer, and its replies.
abstract final class NiimbotCommand {
  static const connect = 0xC1;
  static const printEnd = 0xF3;
  static const pageStart = 0x03;
  static const pageEnd = 0xE3;
  static const printBitmapRow = 0x85;
  static const printBitmapRowIndexed = 0x83;
  static const printEmptyRow = 0x84;
  static const printClear = 0x20;
  static const printerInfo = 0x40;
  static const printerStatusData = 0xA5;
  static const printQuantity = 0x15;
  static const printStart = 0x01;
  static const printStatus = 0xA3;
  static const rfidInfo = 0x1A;
  static const setDensity = 0x21;
  static const setLabelType = 0x23;
  static const setPageSize = 0x13;
  static const heartbeat = 0xDC;
  static const getPaperInfo = 0x59;
  static const printerCheckLine = 0x86;

  // replies
  static const inNotSupported = 0x00;
  static const inPrintError = 0xDB;
  static const inPrinterPageIndex = 0xE0;
  static const inConnect = 0xC2;
  static const inPrintStatus = 0xB3;
  static const inPrintEnd = 0xF4;
  static const inPageStart = 0x04;
  static const inPageEnd = 0xE4;
  static const inRfidInfo = 0x1B;
  static const inPaperInfo = 0x69;
  static const inHeartbeatBasic = 0xDE;
  static const inHeartbeatPrinterInfo = 0xDF;
  static const inHeartbeatAdvanced1 = 0xDD;
  static const inHeartbeatAdvanced2 = 0xD9;

  /// What each request waits for (niimbluelib's commandsMap). Not listed: one-way.
  static const replies = <int, List<int>>{
    connect: [inConnect],
    printEnd: [inPrintEnd],
    pageStart: [inPageStart],
    pageEnd: [inPageEnd],
    printClear: [0x30],
    printerInfo: [0x4F, 0x47, 0x4D, 0x4A, 0x41, 0x4C, 0x43, 0x46, 0x48, 0x4B, 0x49, 0x42, 0x4E],
    printerStatusData: [0xB5],
    printQuantity: [0x16],
    printStart: [0x02],
    printStatus: [inPrintStatus],
    rfidInfo: [inRfidInfo],
    setDensity: [0x31],
    setLabelType: [0x33],
    setPageSize: [0x14],
    heartbeat: [inHeartbeatBasic, inHeartbeatPrinterInfo, inHeartbeatAdvanced1, inHeartbeatAdvanced2],
    getPaperInfo: [inPaperInfo],
    printerCheckLine: [0xD3],
  };
}

/// What the printer can be asked with PrinterInfo (0x40).
enum NiimbotInfo {
  density(1),
  speed(2),
  labelType(3),
  language(6),
  autoShutdownTime(7),
  modelId(8),
  softwareVersion(9),
  battery(10),
  serialNumber(11),
  hardwareVersion(12),
  bluetoothAddress(13),
  printMode(14),
  area(15);

  const NiimbotInfo(this.code);
  final int code;
}

/// The kind of label stock (SetLabelType, and the roll's RFID tag).
enum NiimbotLabelType {
  invalid(0, 'unknown'),
  withGaps(1, 'labels with gaps'),
  black(2, 'black-mark labels'),
  continuous(3, 'continuous tape'),
  perforated(4, 'perforated labels'),
  transparent(5, 'transparent labels'),
  pvcTag(6, 'PVC tags'),
  blackMarkGap(10, 'black-mark labels with gaps'),
  heatShrinkTube(11, 'heat-shrink tube');

  const NiimbotLabelType(this.code, this.label);
  final int code;
  final String label;

  static NiimbotLabelType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => invalid);
}

List<int> _u16(int n) => [(n >> 8) & 0xFF, n & 0xFF];

/// Packet builders (niimbluelib's PacketGenerator).
abstract final class NiimbotPackets {
  static NiimbotPacket connect() => NiimbotPacket(NiimbotCommand.connect);
  static NiimbotPacket printerStatusData() => NiimbotPacket(NiimbotCommand.printerStatusData);
  static NiimbotPacket info(NiimbotInfo what) => NiimbotPacket(NiimbotCommand.printerInfo, [what.code]);
  static NiimbotPacket heartbeat(int type) => NiimbotPacket(NiimbotCommand.heartbeat, [type]);
  static NiimbotPacket rfidInfo() => NiimbotPacket(NiimbotCommand.rfidInfo);
  static NiimbotPacket paperInfo() => NiimbotPacket(NiimbotCommand.getPaperInfo);
  static NiimbotPacket setDensity(int v) => NiimbotPacket(NiimbotCommand.setDensity, [v.clamp(0, 255)]);
  static NiimbotPacket setLabelType(NiimbotLabelType t) =>
      NiimbotPacket(NiimbotCommand.setLabelType, [t.code]);
  static NiimbotPacket printStart1b() => NiimbotPacket(NiimbotCommand.printStart);
  static NiimbotPacket printStart2b(int pages) => NiimbotPacket(NiimbotCommand.printStart, _u16(pages));
  static NiimbotPacket printStart7b(int pages) =>
      NiimbotPacket(NiimbotCommand.printStart, [..._u16(pages), 0, 0, 0, 0, 0]);
  static NiimbotPacket printStart9b(int pages, {int speed = 1}) =>
      NiimbotPacket(NiimbotCommand.printStart, [..._u16(pages), 0, 0, 0, 0, 0, speed, 0]);
  static NiimbotPacket pageStart() => NiimbotPacket(NiimbotCommand.pageStart);
  static NiimbotPacket pageEnd() => NiimbotPacket(NiimbotCommand.pageEnd);
  static NiimbotPacket printEnd() => NiimbotPacket(NiimbotCommand.printEnd);
  static NiimbotPacket printClear() => NiimbotPacket(NiimbotCommand.printClear);
  static NiimbotPacket printStatus({bool oneWay = false}) =>
      NiimbotPacket(NiimbotCommand.printStatus, const [1], oneWay ? const [] : null);
  static NiimbotPacket printQuantity(int n) => NiimbotPacket(NiimbotCommand.printQuantity, _u16(n));
  static NiimbotPacket pageSize2b({required int rows}) =>
      NiimbotPacket(NiimbotCommand.setPageSize, _u16(rows));
  static NiimbotPacket pageSize4b({required int rows, required int cols}) =>
      NiimbotPacket(NiimbotCommand.setPageSize, [..._u16(rows), ..._u16(cols)]);
  static NiimbotPacket pageSize6b({required int rows, required int cols, required int copies}) =>
      NiimbotPacket(NiimbotCommand.setPageSize, [..._u16(rows), ..._u16(cols), ..._u16(copies)]);
  static NiimbotPacket pageSize9b({required int rows, required int cols, required int copies}) =>
      NiimbotPacket(
          NiimbotCommand.setPageSize, [..._u16(rows), ..._u16(cols), ..._u16(copies), ..._u16(0), 0]);
  static NiimbotPacket pageSize13b({required int rows, required int cols, required int copies}) =>
      NiimbotPacket(NiimbotCommand.setPageSize,
          [..._u16(rows), ..._u16(cols), ..._u16(copies), ..._u16(0), 0, 0, 0, ..._u16(0)]);
  static NiimbotPacket emptyRows({required int at, required int repeat}) =>
      NiimbotPacket(NiimbotCommand.printEmptyRow, [..._u16(at), repeat], const []);
  static NiimbotPacket checkLine(int row) =>
      NiimbotPacket(NiimbotCommand.printerCheckLine, [..._u16(row), 1]);

  /// A row of dots; rows with at most 6 black dots are sent as the dots'
  /// positions instead.
  static NiimbotPacket row(NiimbotRow r,
      {required int printhead, CountsMode counts = CountsMode.auto, bool noIndex = false}) {
    final c = NiimbotImage.countPixels(r.data, printhead: printhead, mode: counts);
    if (c.total <= 6 && !noIndex) {
      return NiimbotPacket(NiimbotCommand.printBitmapRowIndexed,
          [..._u16(r.row), ...c.parts, r.repeats, ...NiimbotImage.indexPixels(r.data)], const []);
    }
    return NiimbotPacket(
        NiimbotCommand.printBitmapRow, [..._u16(r.row), ...c.parts, r.repeats, ...r.data], const []);
  }
}

// ----------------------------------------------------------------- replies

class NiimbotError implements Exception {
  const NiimbotError(this.message, {this.code = 0});
  final String message;
  final int code;
  @override
  String toString() => message;
}

class HeadInfo {
  const HeadInfo(
      {required this.hardware,
      required this.software,
      required this.printheadWidth,
      required this.resolutionClass,
      required this.supportsRfid});
  final String hardware, software;
  final int printheadWidth, resolutionClass;
  final bool supportsRfid;
}

class RollRfid {
  const RollRfid(
      {required this.barCode, required this.serial, required this.total, required this.used, required this.type});
  final String barCode, serial;
  final int total, used;
  final NiimbotLabelType type;
  int? get remaining => total > 0 ? (total - used).clamp(0, total) : null;
}

class PaperInfo {
  const PaperInfo({required this.widthMm, required this.heightMm, required this.gapMm, required this.type});
  final double widthMm, heightMm, gapMm;
  final NiimbotLabelType type;
}

class PrintStatus {
  const PrintStatus(
      {required this.page, required this.printProgress, required this.feedProgress, required this.error});
  final int page, printProgress, feedProgress, error;
}

class Heartbeat {
  const Heartbeat({this.battery, this.paperInserted, this.lidClosed});
  final int? battery;
  final bool? paperInserted, lidClosed;
}

abstract final class NiimbotReplies {
  /// A PrintError (0xdb) or NotSupported (0x00) reply as an error.
  static NiimbotError? error(NiimbotPacket p) {
    if (p.command == NiimbotCommand.inPrintError) {
      final code = p.data.isEmpty ? 0 : p.data.first;
      return NiimbotError('The printer reported: ${errorName(code)}.', code: code);
    }
    if (p.command == NiimbotCommand.inNotSupported) {
      return const NiimbotError("The printer doesn't support that.");
    }
    return null;
  }

  static String errorName(int code) => switch (code) {
        0x01 => 'the cover is open',
        0x02 => 'no labels',
        0x03 => 'the battery is low',
        0x04 => 'battery fault',
        0x05 => 'cancelled',
        0x06 => 'bad print data',
        0x07 => 'overheated',
        0x08 => 'paper out',
        0x09 => 'busy',
        0x0A => 'no print head',
        0x0B => 'too cold',
        0x0C => 'print head loose',
        0x0D => 'no ribbon',
        0x0E => 'wrong ribbon',
        0x0F => 'used ribbon',
        0x10 => 'wrong labels',
        0x11 => "couldn't set the labels",
        0x12 => "couldn't set the print mode",
        0x13 => "couldn't set the darkness",
        0x17 => 'disconnected',
        0x18 => 'the label is the wrong size',
        0x32 => 'illegal page',
        0x34 => 'timed out receiving data',
        _ => 'error $code',
      };

  static bool isTrue(NiimbotPacket p) => p.data.length == 1 && p.data[0] == 1;

  /// Connect: 1 connected, 2 connected (protocol 1), 3 connected (ask
  /// PrinterStatusData), 90 firmware errors.
  static int connectResult(NiimbotPacket p) => p.data.isEmpty ? 0 : p.data.first;

  /// PrinterStatusData: protocol version (3, 4 or 5) from the firmware number
  /// at bytes 11–12.
  static int protocolVersion(NiimbotPacket p) {
    if (p.data.length < 13) return 0;
    final n = p.data[11] * 100 + p.data[12];
    if (n >= 204 && n < 300) return 3;
    if (n >= 300 && n < 302) return 4;
    if (n >= 302) return 5;
    return 0;
  }

  static int? modelId(NiimbotPacket p) => switch (p.data.length) {
        1 => p.data[0] << 8,
        2 => p.data[0] << 8 | p.data[1],
        _ => null,
      };

  static int? byte(NiimbotPacket p) => p.data.length == 1 ? p.data[0] : null;

  static int? battery(NiimbotPacket p) {
    final v = byte(p);
    if (v == null) return null;
    return v <= 4 ? v * 25 : v;
  }

  /// HeartbeatBasic reply to a PrinterInfo heartbeat: versions and the print
  /// head's width in dots.
  static HeadInfo? headInfo(NiimbotPacket p) {
    if (p.data.length != 10) return null;
    final d = p.data;
    String v(int h, int l) => (l / 100 + h).toStringAsFixed(2);
    return HeadInfo(
      hardware: v(d[0], d[1]),
      software: v(d[2], d[3]),
      printheadWidth: d[4] << 8 | d[5],
      resolutionClass: d[6],
      supportsRfid: d[8] != 0,
    );
  }

  /// The label roll's RFID tag.
  static RollRfid? rfid(NiimbotPacket p) {
    if (p.data.length <= 1) return null;
    final r = _Reader(p.data);
    if (!r.skip(8)) return null;
    final bar = r.vString(), serial = r.vString(), total = r.u16(), used = r.u16(), type = r.u8();
    if (bar == null || serial == null || total == null || used == null || type == null) return null;
    return RollRfid(
        barCode: bar, serial: serial, total: total, used: used, type: NiimbotLabelType.fromCode(type));
  }

  /// GetPaperInfo (newer printers): the loaded label's size in mm.
  static PaperInfo? paper(NiimbotPacket p, {bool heightIncludesGap = false}) {
    if (p.data.length != 18) return null;
    final r = _Reader(p.data);
    if (!r.skip(4)) return null;
    final type = r.u8(), gap = r.u16(), total = r.u16();
    if (type == null || gap == null || total == null || !r.skip(2)) return null;
    final width = r.u16();
    if (width == null) return null;
    final g = gap / 10, h = total / 10 - (heightIncludesGap ? g : 0);
    return PaperInfo(widthMm: width / 10, heightMm: h, gapMm: g, type: NiimbotLabelType.fromCode(type));
  }

  static PrintStatus? printStatus(NiimbotPacket p) {
    if (p.data.length < 4) return null;
    final d = p.data;
    return PrintStatus(
      page: d[0] << 8 | d[1],
      printProgress: d[2],
      feedProgress: d[3],
      error: d.length == 10 ? d[6] : 0,
    );
  }

  /// Heartbeat (Advanced 1 or 2): battery and whether labels are in.
  static Heartbeat? heartbeat(NiimbotPacket p) {
    final d = p.data;
    int pct(int v) => v <= 4 ? v * 25 : v;
    if (p.command == NiimbotCommand.inHeartbeatAdvanced2 && d.length >= 9) {
      return Heartbeat(battery: pct(d[2]), paperInserted: d[5] == 0, lidClosed: d[4] == 0);
    }
    if (p.command != NiimbotCommand.inHeartbeatAdvanced1) return null;
    return switch (d.length) {
      10 => Heartbeat(battery: pct(d[9])),
      13 => Heartbeat(battery: pct(d[10]), paperInserted: d[11] == 0),
      19 => Heartbeat(battery: pct(d[16]), paperInserted: d[17] == 0),
      20 => Heartbeat(paperInserted: d[18] == 0),
      _ => null,
    };
  }
}

class _Reader {
  _Reader(this.d);
  final List<int> d;
  int i = 0;

  bool skip(int n) {
    if (i + n > d.length) return false;
    i += n;
    return true;
  }

  int? u8() => i < d.length ? d[i++] : null;

  int? u16() {
    if (i + 2 > d.length) return null;
    final v = d[i] << 8 | d[i + 1];
    i += 2;
    return v;
  }

  String? vString() {
    final n = u8();
    if (n == null || n >= 128 || i + n > d.length) return null;
    final s = String.fromCharCodes(d.sublist(i, i + n));
    i += n;
    return s;
  }
}

// ----------------------------------------------------------------- models

enum NiimbotDirection {
  /// The label runs sideways under the head (D11, D110, H1…): the picture is
  /// turned a quarter turn clockwise.
  left,

  /// The label feeds top first (B1, B21, B3S…).
  top,
}

/// How a model prints (niimbluelib's print tasks).
enum NiimbotPrintTask { d11V1, d110, b1, b21V1, b21L2B, d110mV4, h1s }

class NiimbotModel {
  const NiimbotModel({
    required this.name,
    required this.ids,
    required this.dpi,
    required this.direction,
    required this.printheadPixels,
    required this.paperTypes,
    required this.densityMin,
    required this.densityMax,
    required this.densityDefault,
  });

  final String name;
  final List<int> ids;
  final int dpi;
  final NiimbotDirection direction;
  final int printheadPixels;
  final List<NiimbotLabelType> paperTypes;
  final int densityMin, densityMax, densityDefault;

  NiimbotModel copyWith({String? name, int? dpi, NiimbotDirection? direction, int? printheadPixels}) =>
      NiimbotModel(
        name: name ?? this.name,
        ids: ids,
        dpi: dpi ?? this.dpi,
        direction: direction ?? this.direction,
        printheadPixels: printheadPixels ?? this.printheadPixels,
        paperTypes: paperTypes,
        densityMin: densityMin,
        densityMax: densityMax,
        densityDefault: densityDefault,
      );

  /// The printer's name for people: "B21 Pro" for "B21_PRO".
  String get displayName => name.replaceAll('_PRO', ' Pro').replaceAll('_', ' ');

  /// Widest label across the head, mm.
  double get headMm => printheadPixels * 25.4 / dpi;

  /// The print algorithm: by model, then protocol version (niimbluelib's
  /// findPrintTask).
  NiimbotPrintTask printTask(int? protocolVersion) {
    const exact = {
      'D110_M': {4: NiimbotPrintTask.d110mV4},
      'D11': {1: NiimbotPrintTask.d110, 2: NiimbotPrintTask.d110},
    };
    final e = protocolVersion == null ? null : exact[name]?[protocolVersion];
    if (e != null) return e;
    const byModel = {
      NiimbotPrintTask.d11V1: ['D11', 'D11S'],
      NiimbotPrintTask.d110: ['B21S', 'B21S_C2B', 'D110'],
      NiimbotPrintTask.b1: ['D110_M', 'B1', 'B21_C2B', 'M2_H', 'N1', 'D101'],
      NiimbotPrintTask.b21V1: ['B21'],
      NiimbotPrintTask.b21L2B: ['B21_L2B'],
      NiimbotPrintTask.d110mV4: ['D11_H', 'B21_PRO', 'B1_PRO', 'C1', 'EP1C'],
      NiimbotPrintTask.h1s: ['H1S'],
    };
    for (final t in NiimbotPrintTask.values) {
      if (byModel[t]?.contains(name) ?? false) return t;
    }
    if (protocolVersion != null && protocolVersion >= 4) return NiimbotPrintTask.d110mV4;
    // Not in niimbluelib's table: the closest family.
    return direction == NiimbotDirection.left ? NiimbotPrintTask.d110 : NiimbotPrintTask.b1;
  }

  static NiimbotModel? named(String name) => library.where((m) => m.name == name).firstOrNull;
  static NiimbotModel? byId(int id) => library.where((m) => m.ids.contains(id)).firstOrNull;

  /// A model from a Bluetooth name: "B1-G327071185", "D110-A0123…", "B21_PRO-…".
  static NiimbotModel? fromDeviceName(String deviceName) {
    final head = deviceName.toUpperCase().split(RegExp(r'[- ]')).first;
    final key = head.replaceAll('_', '');
    return library.where((m) => m.name.replaceAll('_', '') == key).firstOrNull;
  }

  /// Before the printer says which it is: the D110, the most common small one.
  static final fallback = named('D110')!;

  // niimbluelib printer_models.ts: name, ids, dpi, direction, print head
  // dots, label types, darkness min/max/default.
  static final List<NiimbotModel> library = () {
    const l = NiimbotDirection.left, t = NiimbotDirection.top;
    const g = NiimbotLabelType.withGaps,
        b = NiimbotLabelType.black,
        c = NiimbotLabelType.continuous,
        p = NiimbotLabelType.perforated,
        tr = NiimbotLabelType.transparent,
        pvc = NiimbotLabelType.pvcTag,
        bmg = NiimbotLabelType.blackMarkGap,
        hst = NiimbotLabelType.heatShrinkTube;
    const gbt = [g, b, tr], gt = [g, tr], gbct = [g, b, c, tr], gbcp = [g, b, c, p];
    NiimbotModel m(String n, List<int> ids, int dpi, NiimbotDirection d, int head,
            List<NiimbotLabelType> types, int dn, int dx, int dd) =>
        NiimbotModel(
            name: n,
            ids: ids,
            dpi: dpi,
            direction: d,
            printheadPixels: head,
            paperTypes: types,
            densityMin: dn,
            densityMax: dx,
            densityDefault: dd);
    return [
      m('A1_PRO', [7424], 300, l, 296, [p, c], 1, 5, 3),
      m('A20', [2817], 203, t, 400, gbt, 1, 5, 3),
      m('A203', [2818], 203, t, 400, gbt, 1, 5, 3),
      m('A63', [2054], 300, t, 851, gbt, 1, 15, 10),
      m('A8', [256], 203, t, 576, [b, g, c], 1, 5, 3),
      m('A8_P', [273], 203, t, 576, gbt, 1, 5, 3),
      m('B1', [4096], 203, t, 384, gbt, 1, 5, 3),
      m('B1_PRO', [4097], 300, t, 567, gbt, 1, 5, 3),
      m('B1_SE', [4098], 203, t, 384, gbt, 1, 5, 3),
      m('B11', [51457], 203, t, 384, [g, b, c, p, tr], 6, 15, 10),
      m('B16', [1792], 203, l, 96, gt, 1, 3, 2),
      m('B18', [3584], 203, l, 96, [g, tr, bmg, hst, c], 1, 3, 2),
      m('B18S', [3585], 203, l, 96, [g, tr, bmg, hst, c], 1, 3, 2),
      m('B2', [6913], 203, t, 384, gbt, 1, 5, 3),
      m('B2_PRO', [6912], 300, t, 567, gbt, 1, 5, 3),
      m('B203', [2816], 203, t, 400, gbt, 1, 5, 3),
      m('B21', [768], 203, t, 384, gbct, 1, 5, 3),
      m('B21_PRO', [785], 300, t, 591, gbct, 1, 5, 3),
      m('B21_C2B', [771, 775], 203, t, 384, gbct, 1, 5, 3),
      m('B21_L2B', [769], 203, t, 384, gbt, 1, 5, 3),
      m('B21S', [777], 203, t, 384, gbct, 1, 5, 3),
      m('B21S_C2B', [776], 203, t, 384, gbt, 1, 5, 3),
      m('B3', [52993], 203, t, 600, gbct, 1, 5, 3),
      m('B31', [5632], 203, t, 600, gbt, 1, 5, 3),
      m('B32', [2049], 300, t, 851, gt, 1, 15, 10),
      m('B32R', [2050], 300, t, 851, [g], 1, 15, 10),
      m('B3S', [256, 260, 262], 203, t, 576, gbct, 1, 5, 3),
      m('B3S_A', [275], 203, t, 576, gbct, 1, 5, 3),
      m('B3S_P', [272], 203, t, 576, gbct, 1, 5, 3),
      m('B4', [6656], 203, t, 832, gbt, 1, 5, 3),
      m('B4_PRO', [6657], 300, t, 1229, gbt, 1, 5, 3),
      m('B50', [51713], 203, t, 400, gbcp, 6, 15, 10),
      m('B50W', [51714], 203, t, 384, gbcp, 6, 15, 10),
      m('BETTY', [2561], 203, l, 192, gt, 1, 3, 2),
      m('C1', [5120], 300, l, 178, [c], 1, 5, 3),
      m('D101', [2560], 203, l, 192, gt, 1, 3, 2),
      m('D11', [512], 203, l, 96, gt, 1, 3, 2),
      m('D11_H', [528], 300, l, 142, gt, 1, 5, 3),
      m('D11_PRO', [531], 300, l, 142, gt, 1, 5, 3),
      m('D110', [2304, 2305], 203, l, 96, gt, 1, 3, 2),
      m('D110_M', [2320], 203, l, 96, gt, 1, 5, 3),
      m('D11S', [514], 203, l, 96, gt, 1, 3, 2),
      m('EP1C', [5121], 300, l, 178, [c], 1, 5, 3),
      m('EP2M_H', [4610], 300, t, 567, [g, tr, b, bmg], 1, 5, 3),
      m('EP3M', [6402], 300, t, 851, [g, tr, b, bmg], 1, 5, 3),
      m('ET10', [5376], 203, t, 1600, [c], 3, 3, 3),
      m('FUST', [513], 203, l, 96, gt, 1, 5, 3),
      m('H1', [3840], 203, l, 96, gt, 1, 3, 2),
      m('H1S', [4352], 203, l, 96, [g, c, tr], 1, 3, 2),
      m('JC_M90', [51461], 203, t, 384, gbcp, 6, 15, 10),
      m('K2', [6144], 203, t, 448, gbt, 1, 5, 3),
      m('K3', [4864], 203, t, 640, gbt, 1, 5, 3),
      m('K3_ITD', [4868], 203, t, 640, gbt, 1, 5, 3),
      m('K3_W', [4865], 203, t, 640, gbt, 1, 5, 3),
      m('K4', [7168], 203, t, 832, gbt, 1, 15, 7),
      m('M2_H', [4608], 300, t, 567, [g, tr, b, bmg], 1, 5, 3),
      m('M3', [6400], 300, t, 851, [g, tr, b, bmg], 1, 5, 3),
      m('MP3K', [4866], 203, t, 640, gbt, 1, 5, 3),
      m('MP3K_W', [4867], 203, t, 640, gbt, 1, 5, 3),
      m('N1', [3586], 203, l, 96, [g, hst, tr, bmg, c], 1, 3, 2),
      m('P1', [1024], 300, l, 697, [pvc], 1, 5, 3),
      m('P18', [1026], 300, l, 662, [pvc], 1, 5, 3),
      m('P1S', [1025], 300, l, 662, [pvc], 1, 5, 3),
      m('S1', [51458], 203, t, 384, gbcp, 6, 15, 10),
      m('S3', [51460], 203, t, 384, gbcp, 6, 15, 10),
      m('S6', [261, 259, 258, 257], 203, t, 576, gbt, 1, 5, 3),
      m('S6_P', [274], 203, t, 600, gt, 1, 5, 3),
      m('T2S', [53250], 203, t, 832, [g, b], 1, 20, 15),
      m('T6', [51715], 203, t, 384, gbcp, 6, 15, 10),
      m('T7', [51717], 203, t, 384, gbcp, 6, 15, 10),
      m('T8', [51718], 300, t, 567, gbcp, 6, 15, 10),
      m('T8S', [2053], 300, t, 851, [g], 1, 15, 10),
      m('TP2M_H', [4609], 300, t, 591, gbt, 1, 5, 3),
      m('Z401', [2051], 300, t, 851, gt, 1, 15, 10),
    ];
  }();
}

// ----------------------------------------------------------------- images

/// A 1-bit picture, one bit per dot, rows packed most-significant bit first;
/// set = black.
class Bitmap1 {
  Bitmap1(this.width, this.height) : bytes = Uint8List(((width + 7) ~/ 8) * height);

  /// From a grey picture (0 black … 255 white, [width] per row): darker than
  /// [threshold] prints.
  factory Bitmap1.fromGray(int width, int height, List<int> gray, {int threshold = 160}) {
    final b = Bitmap1(width, height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (gray[y * width + x] < threshold) b.set(x, y, true);
      }
    }
    return b;
  }

  final int width, height;
  final Uint8List bytes;
  int get rowBytes => (width + 7) ~/ 8;

  bool get(int x, int y) => bytes[y * rowBytes + x ~/ 8] & (0x80 >> (x % 8)) != 0;

  void set(int x, int y, bool black) {
    final i = y * rowBytes + x ~/ 8, bit = 0x80 >> (x % 8);
    bytes[i] = black ? bytes[i] | bit : bytes[i] & ~bit;
  }

  void fill(int x, int y, int w, int h) {
    final x0 = x.clamp(0, width), x1 = (x + w).clamp(0, width);
    final y0 = y.clamp(0, height), y1 = (y + h).clamp(0, height);
    for (var yy = y0; yy < y1; yy++) {
      for (var xx = x0; xx < x1; xx++) {
        set(xx, yy, true);
      }
    }
  }

  int get blackCount {
    var n = 0;
    for (final b in bytes) {
      var v = b;
      while (v != 0) {
        n += v & 1;
        v >>= 1;
      }
    }
    return n;
  }
}

enum RowKind { empty, pixels, check }

enum CountsMode { auto, split, total }

class NiimbotRow {
  NiimbotRow(this.kind, this.row, this.repeats, this.black, this.data);
  final RowKind kind;
  final int row;
  int repeats;
  final int black;
  final List<int> data;
}

int _bitCount(int v) {
  var n = 0;
  while (v != 0) {
    n += v & 1;
    v >>= 1;
  }
  return n;
}

/// The picture in the printer's rows (niimbluelib's ImageEncoder).
class NiimbotImage {
  /// Encodes a picture drawn the way the label is read. [NiimbotDirection.left]
  /// turns it a quarter turn clockwise for a sideways head.
  factory NiimbotImage(Bitmap1 b, NiimbotDirection direction) {
    final sideways = direction == NiimbotDirection.left;
    final srcCols = sideways ? b.height : b.width;
    final rows = sideways ? b.width : b.height;
    final cols = (srcCols + 7) ~/ 8 * 8;
    bool dot(int col, int row) => sideways ? b.get(row, b.height - 1 - col) : b.get(col, row);
    final out = <NiimbotRow>[];
    for (var r = 0; r < rows; r++) {
      final bytes = List<int>.filled(cols ~/ 8, 0);
      var black = 0;
      for (var c = 0; c < srcCols; c++) {
        if (dot(c, r)) {
          bytes[c ~/ 8] |= 0x80 >> (c % 8);
          black++;
        }
      }
      final kind = black == 0 ? RowKind.empty : RowKind.pixels;
      final data = black == 0 ? const <int>[] : bytes;
      final last = out.lastOrNull;
      if (last != null && last.kind == kind && _listEq(last.data, data) && last.repeats < 255) {
        last.repeats++;
      } else {
        out.add(NiimbotRow(kind, r, 1, black, data));
      }
      if (r > 0 && r % 200 == 199) out.add(NiimbotRow(RowKind.check, r, 0, 0, const []));
    }
    return NiimbotImage._(cols, rows, out);
  }

  NiimbotImage._(this.cols, this.rows, this.data);

  /// Dots per row (across the head), a multiple of 8.
  final int cols;

  /// Rows (along the feed).
  final int rows;
  final List<NiimbotRow> data;

  /// Black-dot counts for a bitmap packet: three chunks of the head (split)
  /// or the total, little-endian (total).
  static ({int total, List<int> parts}) countPixels(List<int> buf,
      {required int printhead, CountsMode mode = CountsMode.auto}) {
    final chunk = printhead ~/ 8 ~/ 3;
    var split = chunk > 0 && buf.length <= chunk * 3;
    if (mode == CountsMode.total) split = false;
    var total = 0;
    final parts = [0, 0, 0];
    for (var i = 0; i < buf.length; i++) {
      final n = _bitCount(buf[i]);
      total += n;
      if (split && n > 0 && i ~/ chunk < 3) parts[i ~/ chunk] += n;
    }
    if (split) return (total: total, parts: [for (final p in parts) p.clamp(0, 255)]);
    return (total: total, parts: [0, total & 0xFF, (total >> 8) & 0xFF]);
  }

  /// Positions of the black dots, two bytes each.
  static List<int> indexPixels(List<int> data) => [
        for (var i = 0; i < data.length; i++)
          for (var bit = 0; bit < 8; bit++)
            if (data[i] & (0x80 >> bit) != 0) ..._u16(i * 8 + bit),
      ];

  /// The row packets.
  List<NiimbotPacket> packets(
          {required int printhead, CountsMode counts = CountsMode.auto, bool checkLines = false}) =>
      [
        for (final r in data)
          switch (r.kind) {
            RowKind.pixels => NiimbotPackets.row(r, printhead: printhead, counts: counts),
            RowKind.empty => NiimbotPackets.emptyRows(at: r.row, repeat: r.repeats),
            RowKind.check => checkLines ? NiimbotPackets.checkLine(r.row) : null,
          },
      ].nonNulls.toList();
}

// ----------------------------------------------------------------- print jobs

/// One step of a print job, for a connection to carry out.
sealed class NiimbotStep {
  const NiimbotStep();
}

/// Send and wait for the reply (one-way packets just go).
class SendStep extends NiimbotStep {
  const SendStep(this.packet);
  final NiimbotPacket packet;
  @override
  bool operator ==(Object other) => other is SendStep && other.packet == packet;
  @override
  int get hashCode => packet.hashCode;
}

/// Send until the printer answers yes (B21 L2B's PageStart / PageEnd).
class SendUntilTrueStep extends NiimbotStep {
  const SendUntilTrueStep(this.packet, this.attempts);
  final NiimbotPacket packet;
  final int attempts;
}

/// Poll PrintStatus until the printer has done this many pages.
class WaitStatusStep extends NiimbotStep {
  const WaitStatusStep(this.pages);
  final int pages;
  @override
  bool operator ==(Object other) => other is WaitStatusStep && other.pages == pages;
  @override
  int get hashCode => pages;
}

/// Wait for page-index notices until this page (old D11).
class WaitPageIndexStep extends NiimbotStep {
  const WaitPageIndexStep(this.pages);
  final int pages;
}

/// Send PrintEnd until the printer agrees (B21 v1).
class WaitPrintEndStep extends NiimbotStep {
  const WaitPrintEndStep();
  @override
  bool operator ==(Object other) => other is WaitPrintEndStep;
  @override
  int get hashCode => 1;
}

/// PrintEnd.
class EndStep extends NiimbotStep {
  const EndStep();
  @override
  bool operator ==(Object other) => other is EndStep;
  @override
  int get hashCode => 2;
}

class NiimbotPage {
  NiimbotPage(this.image, int copies) : copies = copies < 1 ? 1 : copies;
  final NiimbotImage image;
  final int copies;
}

abstract final class NiimbotJob {
  /// The steps to print these pages on this model (niimbluelib's print tasks).
  static List<NiimbotStep> steps({
    required NiimbotPrintTask task,
    required List<NiimbotPage> pages,
    required int density,
    required NiimbotLabelType labelType,
    required int printhead,
  }) {
    final total = pages.fold(0, (n, p) => n + p.copies);
    final s = <NiimbotStep>[];
    void send(List<NiimbotPacket> ps) => s.addAll(ps.map(SendStep.new));
    final dens = NiimbotPackets.setDensity(density), type = NiimbotPackets.setLabelType(labelType);

    switch (task) {
      case NiimbotPrintTask.b1:
        send([dens, type, NiimbotPackets.printStart7b(total)]);
      case NiimbotPrintTask.h1s:
        send([dens, type, NiimbotPackets.printStart2b(total)]);
      case NiimbotPrintTask.d110mV4:
        send([type, dens, NiimbotPackets.printStart9b(total)]);
      case NiimbotPrintTask.d11V1 || NiimbotPrintTask.d110 || NiimbotPrintTask.b21V1 || NiimbotPrintTask.b21L2B:
        send([dens, type, NiimbotPackets.printStart1b()]);
    }

    var printed = 0;
    for (final page in pages) {
      final img = page.image, n = page.copies;
      final rows = img.packets(printhead: printhead);
      switch (task) {
        case NiimbotPrintTask.b1:
          send([
            NiimbotPackets.pageStart(),
            NiimbotPackets.pageSize6b(rows: img.rows, cols: img.cols, copies: n),
            ...rows,
            NiimbotPackets.pageEnd(),
          ]);
        case NiimbotPrintTask.h1s:
          send([
            NiimbotPackets.pageStart(),
            NiimbotPackets.pageSize9b(rows: img.rows, cols: img.cols, copies: n),
            ...rows,
            NiimbotPackets.pageEnd(),
          ]);
        case NiimbotPrintTask.d110:
          // The D110 takes one page at a time: wait for it before the next.
          send([
            NiimbotPackets.printClear(),
            NiimbotPackets.pageStart(),
            NiimbotPackets.pageSize4b(rows: img.rows, cols: img.cols),
            NiimbotPackets.printQuantity(n),
            ...rows,
            NiimbotPackets.pageEnd(),
          ]);
          printed += n;
          s.add(WaitStatusStep(printed));
        case NiimbotPrintTask.d11V1:
          send([
            NiimbotPackets.printClear(),
            NiimbotPackets.pageStart(),
            NiimbotPackets.pageSize2b(rows: img.rows),
            NiimbotPackets.printQuantity(n),
            ...rows,
            NiimbotPackets.pageEnd(),
          ]);
        case NiimbotPrintTask.d110mV4:
          send([
            NiimbotPackets.printStatus(oneWay: true),
            NiimbotPackets.pageSize13b(rows: img.rows, cols: img.cols, copies: n),
            ...rows,
            NiimbotPackets.pageEnd(),
          ]);
        case NiimbotPrintTask.b21V1:
          final checked = img.packets(printhead: printhead, counts: CountsMode.total, checkLines: true);
          for (var i = 0; i < n; i++) {
            send([
              NiimbotPackets.pageStart(),
              NiimbotPackets.pageSize4b(rows: img.rows, cols: img.cols),
              ...checked,
              NiimbotPackets.pageEnd(),
            ]);
          }
        case NiimbotPrintTask.b21L2B:
          final checked = img.packets(printhead: printhead, counts: CountsMode.total, checkLines: true);
          for (var i = 0; i < n; i++) {
            s.add(SendUntilTrueStep(NiimbotPackets.pageStart(), 5));
            send([NiimbotPackets.pageSize4b(rows: img.rows, cols: img.cols), ...checked]);
            s.add(SendUntilTrueStep(NiimbotPackets.pageEnd(), 20));
          }
      }
    }

    switch (task) {
      case NiimbotPrintTask.b1 || NiimbotPrintTask.h1s || NiimbotPrintTask.d110mV4:
        s.add(WaitStatusStep(total));
      case NiimbotPrintTask.d11V1:
        s.add(WaitPageIndexStep(total));
      case NiimbotPrintTask.b21V1:
        s.add(const WaitPrintEndStep());
      case NiimbotPrintTask.d110 || NiimbotPrintTask.b21L2B:
        break;
    }
    if (task != NiimbotPrintTask.b21V1) s.add(const EndStep());
    if (task == NiimbotPrintTask.d110mV4) s.add(SendStep(NiimbotPackets.heartbeat(1).oneWayCopy));
    return s;
  }
}
