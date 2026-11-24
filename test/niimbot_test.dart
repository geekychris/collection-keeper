import 'package:collection_keeper/src/labels/label.dart';
import 'package:collection_keeper/src/labels/niimbot.dart';
import 'package:flutter_test/flutter_test.dart';

// Ported from parts-inventory-apple's NiimbotTests.swift. Fixtures are
// niimbluelib's test/dumps.ts: a B1 on firmware 5.22 and a B21 Pro on 3.09.

List<int> hex(String s) => [for (final b in s.split(' ')) int.parse(b, radix: 16)];
NiimbotPacket packet(String s) => NiimbotPacket.parse(hex(s));

Bitmap1 bitmap(int w, int h, void Function(Bitmap1 b) draw) => Bitmap1(w, h)..let(draw);

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}

void main() {
  group('packets', () {
    test('requests match the dumps', () {
      expect(NiimbotPackets.connect().bytes, hex('03 55 55 c1 01 01 c1 aa aa'));
      expect(NiimbotPackets.printerStatusData().bytes, hex('55 55 a5 01 01 a5 aa aa'));
      expect(NiimbotPackets.info(NiimbotInfo.modelId).bytes, hex('55 55 40 01 08 49 aa aa'));
      expect(NiimbotPackets.info(NiimbotInfo.serialNumber).bytes, hex('55 55 40 01 0b 4a aa aa'));
      expect(NiimbotPackets.heartbeat(3).bytes, hex('55 55 dc 01 03 de aa aa'));
      expect(NiimbotPackets.heartbeat(4).bytes, hex('55 55 dc 01 04 d9 aa aa'));
      expect(NiimbotPackets.rfidInfo().bytes, hex('55 55 1a 01 01 1a aa aa'));
      expect(NiimbotPackets.paperInfo().bytes, hex('55 55 59 01 01 59 aa aa'));
    });

    test('reply ids and one-way packets', () {
      expect(NiimbotPackets.connect().replies, [0xC2]);
      expect(NiimbotPackets.printStatus(oneWay: true).oneWay, isTrue);
      expect(NiimbotPackets.emptyRows(at: 0, repeat: 3).oneWay, isTrue);
      expect(NiimbotPackets.pageEnd().oneWay, isFalse);
    });

    test('parses and checks', () {
      final p = packet('55 55 4a 01 04 4f aa aa');
      expect(p.command, 0x4A);
      expect(p.data, [4]);
      expect(NiimbotReplies.battery(p), 100);
      expect(() => packet('55 55 4a 01 04 4e aa aa'), throwsA(isA<PacketParseError>()));
      expect(() => packet('55 55 4a 01 04 4f aa ab'), throwsA(isA<PacketParseError>()));
    });

    test('splits bundles and keeps partial packets', () {
      final (:packets, :rest) = NiimbotPacket.split(hex('55 55 4a 01 04 4f aa aa 55 55 f6 01 01 f6 aa aa 55 55 4a'));
      expect(packets.map((p) => p.command), [0x4A, 0xF6]);
      expect(rest, hex('55 55 4a'));
      final more = NiimbotPacket.split([...rest, ...hex('01 04 4f aa aa')]);
      expect(more.packets, hasLength(1));
      expect(more.rest, isEmpty);
      expect(NiimbotPacket.split(hex('12 34 55 55')).packets, isEmpty);
      expect(NiimbotPacket.split(hex('12 34 55 55')).rest, isEmpty);
    });

    test('models from their ids and Bluetooth names', () {
      final b1 = packet('55 55 48 02 10 00 5a aa aa');
      expect(NiimbotReplies.modelId(b1), 4096);
      expect(NiimbotModel.byId(4096)?.name, 'B1');
      final pro = packet('55 55 48 02 03 11 58 aa aa');
      expect(NiimbotReplies.modelId(pro), 785);
      expect(NiimbotModel.byId(785)?.name, 'B21_PRO');
      expect(NiimbotModel.byId(2304)?.name, 'D110');
      expect(NiimbotModel.fromDeviceName('B1-G327071185')?.name, 'B1');
      expect(NiimbotModel.fromDeviceName('D110-A0123456')?.name, 'D110');
      expect(NiimbotModel.fromDeviceName('B21_PRO-H613')?.name, 'B21_PRO');
      expect(NiimbotModel.fromDeviceName('AirPods'), isNull);
    });

    test('protocol versions', () {
      expect(
          NiimbotReplies.protocolVersion(
              packet('55 55 b5 10 30 30 03 20 00 c8 00 00 00 0f 01 02 04 01 98 00 df aa aa')),
          3);
      expect(
          NiimbotReplies.protocolVersion(
              packet('55 55 b5 10 30 30 07 d0 00 64 00 00 00 0f 01 03 02 03 f5 00 ef aa aa')),
          5);
    });

    test('head info', () {
      final h = NiimbotReplies.headInfo(packet('55 55 de 0a 05 0a 05 16 01 80 02 02 01 00 48 aa aa'))!;
      expect(h.printheadWidth, 384);
      expect(h.hardware, '5.10');
      expect(h.software, '5.22');
      expect(h.resolutionClass, 2);
      expect(h.supportsRfid, isTrue);
    });

    test('roll RFID tag', () {
      final r = NiimbotReplies.rfid(packet(
          '55 55 1b 27 88 1d 7e 4f d9 97 00 00 08 31 30 32 36 32 32 36 30 10 50 5a 31 47 32 32 31 33 32 32 '
          '30 30 34 32 30 35 01 14 00 99 01 3d aa aa'))!;
      expect(r.barCode, '10262260');
      expect(r.serial, 'PZ1G221322004205');
      expect((r.total, r.used, r.remaining), (276, 153, 123));
      expect(r.type, NiimbotLabelType.withGaps);
      // The B21 Pro adds a capacity field.
      final pro = NiimbotReplies.rfid(packet(
          '55 55 1b 29 88 1d 7e 4f d9 97 00 00 08 31 30 32 36 32 32 36 30 10 50 5a 31 47 32 32 31 33 32 32 '
          '30 30 34 32 30 35 01 14 00 99 01 00 e6 d5 aa aa'))!;
      expect(pro.total, 276);
      expect(NiimbotReplies.rfid(NiimbotPacket(0x1B, [0], [])), isNull);
    });

    test('paper info and roll size', () {
      expect(NiimbotReplies.paper(packet('55 55 69 04 00 23 00 23 6d aa aa')), isNull);
      // gap 3 mm, 30.0 mm long, 50.0 mm wide, labels with gaps
      final p = NiimbotReplies.paper(
          NiimbotPacket(0x69, [0, 24, 0, 240, 1, 0, 30, 1, 44, 1, 144, 1, 244, 0, 0, 0, 0, 0], []))!;
      expect((p.widthMm, p.heightMm, p.gapMm, p.type), (50.0, 30.0, 3.0, NiimbotLabelType.withGaps));
      final roll = LabelSize.fromPaper(p, NiimbotModel.named('B1')!)!;
      expect((roll.w, roll.h), (50.0, 30.0));
      // Sideways printers report the side across the head as the width.
      const small = PaperInfo(widthMm: 12, heightMm: 30, gapMm: 2, type: NiimbotLabelType.withGaps);
      final s = LabelSize.fromPaper(small, NiimbotModel.named('D110')!)!;
      expect((s.w, s.h), (30.0, 12.0));
    });

    test('print status and errors', () {
      final s = NiimbotReplies.printStatus(NiimbotPacket(0xB3, [0, 2, 100, 100], []))!;
      expect((s.page, s.error), (2, 0));
      final e = NiimbotReplies.printStatus(NiimbotPacket(0xB3, [0, 0, 0, 0, 0, 0, 2, 0, 0, 0], []))!;
      expect(e.error, 2);
      expect(NiimbotReplies.error(NiimbotPacket(0xDB, [1], []))?.message, 'The printer reported: the cover is open.');
    });

    test('heartbeats', () {
      final a2 = NiimbotReplies.heartbeat(NiimbotPacket(0xD9, hex('20 41 04 4d 00 00 01 00 00'), []))!;
      expect((a2.battery, a2.paperInserted, a2.lidClosed), (100, true, true));
      final d110 = NiimbotReplies.heartbeat(NiimbotPacket(0xDD, [0, 0, 0, 0, 0, 0, 0, 0, 0, 3], []))!;
      expect(d110.battery, 75);
    });
  });

  group('images', () {
    test('rows, repeats and empty rows', () {
      final b = bitmap(16, 5, (b) {
        b.fill(0, 1, 8, 2); // two identical rows
        b.set(15, 4, true);
      });
      final img = NiimbotImage(b, NiimbotDirection.top);
      expect((img.cols, img.rows), (16, 5));
      expect(img.data.map((r) => r.kind), [RowKind.empty, RowKind.pixels, RowKind.empty, RowKind.pixels]);
      expect(img.data[1].repeats, 2);
      expect(img.data[1].data, [0xFF, 0x00]);
      expect(img.data[3].data, [0x00, 0x01]);
      expect(img.data[3].black, 1);
    });

    test('sideways printers turn the picture a quarter clockwise', () {
      // Read as a 3-wide, 2-high label; one dot at the top left.
      final b = bitmap(3, 2, (b) => b.set(0, 0, true));
      final img = NiimbotImage(b, NiimbotDirection.left);
      expect((img.rows, img.cols), (3, 8));
      // Top left of the label → first row, far side of the head (column height-1).
      expect(img.data.first.kind, RowKind.pixels);
      expect(img.data.first.data, [0x40]);
    });

    test('check rows every 200', () {
      final b = bitmap(8, 420, (b) => b.fill(0, 0, 8, 420));
      final img = NiimbotImage(b, NiimbotDirection.top);
      expect(img.data.where((r) => r.kind == RowKind.check).map((r) => r.row), [199, 399]);
      expect(img.data.where((r) => r.kind == RowKind.pixels).fold(0, (n, r) => n + r.repeats), 420);
      expect(img.packets(printhead: 96), hasLength(3));
      expect(img.packets(printhead: 96, checkLines: true), hasLength(5));
    });

    test('pixel counts', () {
      // 96-dot head: chunks of 4 bytes.
      final buf = [0xFF, 0, 0, 0, 0x0F, 0, 0, 0, 0x01, 0, 0, 0];
      final split = NiimbotImage.countPixels(buf, printhead: 96);
      expect(split.total, 13);
      expect(split.parts, [8, 4, 1]);
      expect(NiimbotImage.countPixels(buf, printhead: 96, mode: CountsMode.total).parts, [0, 13, 0]);
      // Wider than the head: the total, little-endian.
      final wide = NiimbotImage.countPixels(List.filled(48, 0xFF), printhead: 96);
      expect(wide.total, 384);
      expect(wide.parts, [0, 0x80, 0x01]);
    });

    test('rows with few dots are sent as positions', () {
      final b = bitmap(16, 1, (b) => b..set(1, 0, true)..set(9, 0, true));
      final p = NiimbotPackets.row(NiimbotImage(b, NiimbotDirection.top).data[0], printhead: 96);
      expect(p.command, 0x83);
      expect(p.data, [0, 0, 2, 0, 0, 1, 0, 1, 0, 9]);
      final dense = bitmap(16, 1, (b) => b.fill(0, 0, 16, 1));
      final q = NiimbotPackets.row(NiimbotImage(dense, NiimbotDirection.top).data[0], printhead: 96);
      expect(q.command, 0x85);
      expect(q.data, [0, 0, 16, 0, 0, 1, 0xFF, 0xFF]);
    });

    test('grey threshold', () {
      final b = Bitmap1.fromGray(2, 1, [10, 250]);
      expect((b.get(0, 0), b.get(1, 0)), (true, false));
    });
  });

  group('print jobs', () {
    NiimbotPage page([int copies = 1]) =>
        NiimbotPage(NiimbotImage(bitmap(16, 4, (b) => b.fill(0, 0, 16, 1)), NiimbotDirection.top), copies);
    bool isWait(NiimbotStep s) => s is WaitStatusStep;

    test('print task by model and protocol', () {
      NiimbotPrintTask t(String m, int v) => NiimbotModel.named(m)!.printTask(v);
      expect(t('B1', 3), NiimbotPrintTask.b1);
      expect(t('D110', 0), NiimbotPrintTask.d110);
      expect(t('D11', 0), NiimbotPrintTask.d11V1);
      expect(t('D11', 1), NiimbotPrintTask.d110);
      expect(t('D110_M', 4), NiimbotPrintTask.d110mV4);
      expect(t('D110_M', 3), NiimbotPrintTask.b1);
      expect(t('B21_PRO', 5), NiimbotPrintTask.d110mV4);
      expect(t('B21', 1), NiimbotPrintTask.b21V1);
      expect(t('H1S', 3), NiimbotPrintTask.h1s);
      expect(t('B3S', 5), NiimbotPrintTask.d110mV4);
      expect(t('B3S', 1), NiimbotPrintTask.b1);
    });

    test('B1 job', () {
      final s = NiimbotJob.steps(
          task: NiimbotPrintTask.b1,
          pages: [page(2), page()],
          density: 3,
          labelType: NiimbotLabelType.withGaps,
          printhead: 384);
      expect(s.take(3), [
        SendStep(NiimbotPackets.setDensity(3)),
        SendStep(NiimbotPackets.setLabelType(NiimbotLabelType.withGaps)),
        SendStep(NiimbotPackets.printStart7b(3)),
      ]);
      expect(s, contains(SendStep(NiimbotPackets.pageSize6b(rows: 4, cols: 16, copies: 2))));
      expect(s.skip(s.length - 2), [const WaitStatusStep(3), const EndStep()]);
    });

    test('the D110 waits after each page', () {
      final s = NiimbotJob.steps(
          task: NiimbotPrintTask.d110,
          pages: [page(), page(2)],
          density: 2,
          labelType: NiimbotLabelType.withGaps,
          printhead: 96);
      expect(s.where(isWait), [const WaitStatusStep(1), const WaitStatusStep(3)]);
      expect(s.last, const EndStep());
      expect(s, contains(SendStep(NiimbotPackets.printQuantity(2))));
    });

    test('B21 v1 repeats pages and polls PrintEnd', () {
      final s = NiimbotJob.steps(
          task: NiimbotPrintTask.b21V1,
          pages: [page(2)],
          density: 3,
          labelType: NiimbotLabelType.withGaps,
          printhead: 384);
      expect(s.where((x) => x == SendStep(NiimbotPackets.pageStart())), hasLength(2));
      expect(s.last, const WaitPrintEndStep());
    });

    test('v4 sends status one-way first', () {
      final s = NiimbotJob.steps(
          task: NiimbotPrintTask.d110mV4,
          pages: [page()],
          density: 3,
          labelType: NiimbotLabelType.withGaps,
          printhead: 591);
      expect(s[2], SendStep(NiimbotPackets.printStart9b(1)));
      expect(s[3], SendStep(NiimbotPackets.printStatus(oneWay: true)));
      expect(s.last, SendStep(NiimbotPackets.heartbeat(1).oneWayCopy));
    });
  });

  group('label sizes', () {
    test('in dots, clipped to the head', () {
      final d110 = NiimbotModel.named('D110')!, b1 = NiimbotModel.named('B1')!;
      final small = LabelSize.named('30x12')!.canvas(d110);
      expect((small.w, small.h, small.clipped), (240, 96, false));
      expect(LabelSize.named('30x15')!.canvas(d110).clipped, isTrue);
      expect(LabelSize.named('50x30')!.canvas(b1).w, 384);
      expect(LabelSize.named('40x30')!.fits(b1), isTrue);
      expect(LabelSize.named('50x40')!.fits(d110), isFalse);
      expect(LabelSize.usual(d110).id, '30x12');
      expect(LabelSize.usual(NiimbotModel.named('B21')!).id, '40x30');
    });
  });
}
