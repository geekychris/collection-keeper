import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection_keeper/src/data/codes.dart';
import 'package:collection_keeper/src/labels/label.dart';
import 'package:collection_keeper/src/labels/niimbot.dart';
import 'package:collection_keeper/src/labels/niimbot_session.dart';
import 'package:collection_keeper/src/labels/pdf_labels.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pretend B1 on the other end of the link: answers what the app asks the
/// way the dumps in niimbot_test.dart show, and "prints" the pages it gets.
class FakeB1 implements NiimbotLink {
  final _out = StreamController<Uint8List>();
  final received = <NiimbotPacket>[];
  int pagesWanted = 0, pagesEnded = 0, rows = 0;

  @override
  Stream<Uint8List> get incoming => _out.stream;

  @override
  Future<void> close() => _out.close();

  @override
  Future<void> write(Uint8List bytes) async {
    final raw = bytes.first == 0x03 ? bytes.sublist(1) : bytes;
    final p = NiimbotPacket.parse(raw);
    received.add(p);
    void reply(int cmd, List<int> data) => scheduleMicrotask(
        () => _out.add(NiimbotPacket(cmd, data, const []).bytes));
    switch (p.command) {
      case NiimbotCommand.connect:
        reply(0xC2, [1]);
      case NiimbotCommand.printerInfo:
        switch (p.data.first) {
          case 8: // model id
            reply(0x48, [0x10, 0x00]);
          case 10: // battery
            reply(0x4A, [3]);
          case 3: // label type
            reply(0x43, [1]);
          default:
            reply(0x00, [0]);
        }
      case NiimbotCommand.heartbeat:
        reply(0xDE, [5, 10, 5, 22, 1, 128, 2, 2, 1, 0]);
      case NiimbotCommand.rfidInfo:
        reply(0x1B, [0]);
      case NiimbotCommand.getPaperInfo:
        reply(0x00, [0]); // not supported
      case NiimbotCommand.setDensity || NiimbotCommand.setLabelType:
        reply(p.command + 0x10, [1]);
      case NiimbotCommand.printStart:
        pagesWanted = p.data[0] << 8 | p.data[1];
        reply(0x02, [1]);
      case NiimbotCommand.pageStart:
        reply(0x04, [1]);
      case NiimbotCommand.setPageSize:
        reply(0x14, [1]);
      case NiimbotCommand.pageEnd:
        pagesEnded += p.data.isEmpty ? 0 : 1;
        reply(0xE4, [1]);
      case NiimbotCommand.printBitmapRow || NiimbotCommand.printBitmapRowIndexed || NiimbotCommand.printEmptyRow:
        rows++;
      case NiimbotCommand.printStatus:
        reply(0xB3, [0, pagesWanted, 100, 100]);
      case NiimbotCommand.printEnd:
        reply(0xF4, [1]);
    }
  }
}

void main() {
  test('label codes pack an id small and read back', () {
    const id = '3f2b8c1e-9a4d-4e6f-8b7a-0c1d2e3f4a5b';
    final code = labelCode(CodeKind.item, id);
    expect(code, startsWith('ck:i:'));
    expect(code.length, 27);
    expect(parseLabelCode(code), (kind: CodeKind.item, id: id));
    expect(parseLabelCode(labelCode(CodeKind.location, id)), (kind: CodeKind.location, id: id));
    expect(parseLabelCode('https://collections.example.com/l/$id'), (kind: CodeKind.location, id: id));
    expect(parseLabelCode('ck:x:abc'), isNull);
    expect(parseLabelCode('hello'), isNull);
  });

  test('connects to a B1 and prints two labels', () async {
    final printer = FakeB1();
    final session = NiimbotSession(printer, packetGap: Duration.zero);
    final info = await session.handshake('B1-G327071185');
    expect(info.model?.name, 'B1');
    expect(info.battery, 75);
    expect(info.labelType, NiimbotLabelType.withGaps);
    expect(info.head?.printheadWidth, 384);
    expect(info.printTask, NiimbotPrintTask.b1);

    final canvas = LabelSize.named('40x30')!.canvas(info.effectiveModel);
    final labels = [
      for (var i = 0; i < 2; i++) Bitmap1(canvas.w, canvas.h)..fill(10 + i, 10, 50, 50),
    ];
    final progress = <(int, int)>[];
    await session.printLabels(labels, density: 3, progress: (d, t) => progress.add((d, t)));

    expect(printer.pagesWanted, 2);
    expect(printer.pagesEnded, 2);
    expect(printer.rows, greaterThan(0));
    expect(printer.received.where((p) => p.command == NiimbotCommand.setPageSize).first.data,
        [0, canvas.h, 1, 64, 0, 1], reason: '${canvas.h} rows of 320 dots, one copy');
    expect(progress.last, (2, 2));
    expect(printer.received.last.command, NiimbotCommand.printEnd);
    await session.close();
  });

  test('a printer error stops the job with its reason', () async {
    final printer = _CoverOpen();
    final session = NiimbotSession(printer, packetGap: Duration.zero);
    await session.handshake('B1-1');
    await expectLater(
      session.printLabels([Bitmap1(320, 240)..fill(0, 0, 8, 8)]),
      throwsA(isA<NiimbotError>().having((e) => e.message, 'message', contains('cover is open'))),
    );
  });

  testWidgets('the rendered label carries the QR code dot for dot', (tester) async {
    final content = LabelContent(
      code: labelCode(CodeKind.item, '3f2b8c1e-9a4d-4e6f-8b7a-0c1d2e3f4a5b'),
      title: 'Amiga 1200',
      lines: ['Shelf 2', 'Computers'],
    );
    const w = 320, h = 240, dpi = 203;
    final bitmap = (await tester.runAsync(() => renderLabel(content, w: w, h: h, dpi: dpi)))!;
    final modules = qrModules(content.code);
    final place = qrPlacement(w, h, modules.length, dpi)!;
    expect(place.module, greaterThanOrEqualTo(2));
    var mismatches = 0;
    for (var r = 0; r < modules.length; r++) {
      for (var c = 0; c < modules.length; c++) {
        final x = place.x + place.module * (c + 1) + place.module ~/ 2;
        final y = place.y + place.module * (r + 1) + place.module ~/ 2;
        if (bitmap.get(x, y) != modules[r][c]) mismatches++;
      }
    }
    expect(mismatches, 0);
    // The quiet zone is clear and there's text to the right of the code.
    expect(bitmap.get(place.x + place.module ~/ 2, place.y + place.module ~/ 2), isFalse);
    var textDots = 0;
    for (var y = 0; y < h; y++) {
      for (var x = place.x + place.size + 4; x < w; x++) {
        if (bitmap.get(x, y)) textDots++;
      }
    }
    expect(textDots, greaterThan(50));
  });

  test('a 12 mm label still fits a readable QR code', () {
    final modules = qrModules(labelCode(CodeKind.location, '3f2b8c1e-9a4d-4e6f-8b7a-0c1d2e3f4a5b')).length;
    final d110 = LabelSize.named('30x12')!.canvas(NiimbotModel.named('D110')!);
    final place = qrPlacement(d110.w, d110.h, modules, 203);
    expect(place, isNotNull);
    expect(place!.module, greaterThanOrEqualTo(2));
  });

  testWidgets('PDF labels in each layout, in a font with accents and arrows', (tester) async {
    final labels = [
      for (var i = 0; i < 30; i++)
        LabelContent(code: 'ck:i:$i', title: 'Café № $i', lines: ['Warehouse › Shelf $i']),
    ];
    for (final layout in PdfLabelLayout.values) {
      final pdf = await labelsPdf(labels, LabelSize.named(layout == PdfLabelLayout.a4 ? '25x25' : '40x30')!, layout);
      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      final pages = RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(pdf)).length;
      expect(pages, layout == PdfLabelLayout.roll ? 30 : lessThan(30), reason: layout.name);
    }
  });
}

class _CoverOpen extends FakeB1 {
  @override
  Future<void> write(Uint8List bytes) async {
    final raw = bytes.first == 0x03 ? bytes.sublist(1) : bytes;
    if (NiimbotPacket.parse(raw).command == NiimbotCommand.printStart) {
      scheduleMicrotask(() => _out.add(NiimbotPacket(0xDB, [1], const []).bytes));
      return;
    }
    return super.write(bytes);
  }
}
