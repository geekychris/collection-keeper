import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:qr/qr.dart';

import 'niimbot.dart';

/// A label roll as printed on its box: width × height in mm, the way the
/// label is read.
class LabelSize {
  const LabelSize(this.id, this.w, this.h, {this.small = false});
  final String id;
  final double w, h;

  /// For the small printers (D11, D110, H1…), which feed sideways, so their
  /// 12–15 mm side runs across the head.
  final bool small;

  String get name => '${_mm(w)} × ${_mm(h)} mm';
  static String _mm(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  static const all = [
    LabelSize('30x12', 30, 12, small: true),
    LabelSize('40x12', 40, 12, small: true),
    LabelSize('30x15', 30, 15, small: true),
    LabelSize('50x14', 50, 14, small: true),
    LabelSize('25x25', 25, 25),
    LabelSize('30x20', 30, 20),
    LabelSize('40x20', 40, 20),
    LabelSize('40x30', 40, 30),
    LabelSize('50x25', 50, 25),
    LabelSize('50x30', 50, 30),
    LabelSize('50x40', 50, 40),
  ];

  static LabelSize? named(String id) => all.where((s) => s.id == id).firstOrNull;

  /// The label in dots as read, and whether it's wider than the head (only
  /// the head's width prints).
  ({int w, int h, bool clipped}) canvas(NiimbotModel m) {
    int px(double mm) => math.max(8, (mm * m.dpi / 25.4).round());
    var w = px(this.w), h = px(this.h), clipped = false;
    if (m.direction == NiimbotDirection.left) {
      if (h > m.printheadPixels) (h, clipped) = (m.printheadPixels, true);
    } else if (w > m.printheadPixels) {
      (w, clipped) = (m.printheadPixels, true);
    }
    return (w: w, h: h, clipped: clipped);
  }

  /// Whether the side that runs across the head fits it.
  bool fits(NiimbotModel m) {
    final across = m.direction == NiimbotDirection.left ? h : w;
    return across * m.dpi / 25.4 <= m.printheadPixels * 1.05;
  }

  /// The loaded roll from the printer's paper info.
  static LabelSize? fromPaper(PaperInfo p, NiimbotModel m) {
    final a = p.widthMm, b = p.heightMm;
    if (a < 5 || a > 120 || b < 5 || b > 200) return null;
    final (w, h) = m.direction == NiimbotDirection.left ? (b, a) : (a, b);
    return LabelSize('roll', w, h, small: m.direction == NiimbotDirection.left);
  }

  /// A sensible size for a printer that hasn't said what's loaded.
  static LabelSize usual(NiimbotModel m) => m.direction == NiimbotDirection.left
      ? named('30x12')!
      : (m.headMm >= 49 ? named('50x30')! : named('40x30')!);
}

/// What goes on a label: a QR code, a title and a few smaller lines.
class LabelContent {
  const LabelContent({required this.code, required this.title, this.lines = const []});
  final String code;
  final String title;
  final List<String> lines;
}

/// The QR code's modules, dark = true, without a quiet zone.
List<List<bool>> qrModules(String data) {
  final code = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
  final image = QrImage(code);
  return [
    for (var r = 0; r < image.moduleCount; r++)
      [for (var c = 0; c < image.moduleCount; c++) image.isDark(r, c)],
  ];
}

/// Where the QR code goes on a label [w] × [h] dots: whole dots per module,
/// at least 2, with a one-module quiet zone inside the margin, and no more
/// than about half the width. Null when the label is too small for a
/// readable code.
({int x, int y, int module, int size})? qrPlacement(int w, int h, int modules, int dpi) {
  final margin = (dpi * 0.8 / 25.4).round();
  // As tall as the label allows, but leaving room for text beside it.
  final module = math.min((h - 2 * margin) ~/ (modules + 2), (w * 0.55) ~/ (modules + 2));
  if (module < 2) return null;
  final size = module * (modules + 2);
  return (x: margin, y: (h - size) ~/ 2, module: module, size: size);
}

/// Draws [content] on a [w] × [h] dot label and returns the 1-bit picture:
/// the QR code at the left, the title in bold beside it, then the lines,
/// each as large as fits.
Future<Bitmap1> renderLabel(LabelContent content, {required int w, required int h, required int dpi}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  final black = ui.Paint()..color = const ui.Color(0xFF000000);
  final margin = (dpi * 0.8 / 25.4).round();

  final modules = qrModules(content.code);
  final qr = qrPlacement(w, h, modules.length, dpi);
  var textLeft = margin.toDouble();
  if (qr != null) {
    final origin = qr.module; // the quiet zone
    for (var r = 0; r < modules.length; r++) {
      for (var c = 0; c < modules.length; c++) {
        if (!modules[r][c]) continue;
        canvas.drawRect(
          ui.Rect.fromLTWH((qr.x + origin + c * qr.module).toDouble(),
              (qr.y + origin + r * qr.module).toDouble(), qr.module.toDouble(), qr.module.toDouble()),
          black,
        );
      }
    }
    textLeft = (qr.x + qr.size + margin ~/ 2).toDouble();
  }

  final textWidth = w - textLeft - margin;
  final textHeight = (h - 2 * margin).toDouble();
  if (textWidth > 8) {
    final paragraphs = _fitText(content, textWidth, textHeight, dpi);
    final total = paragraphs.fold(0.0, (a, p) => a + p.height);
    var y = margin + (textHeight - total) / 2;
    for (final p in paragraphs) {
      canvas.drawParagraph(p, ui.Offset(textLeft, y));
      y += p.height;
    }
  }

  final image = await recorder.endRecording().toImage(w, h);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  final gray = Uint8List(w * h);
  final px = rgba.buffer.asUint8List();
  for (var i = 0; i < w * h; i++) {
    gray[i] = (px[i * 4] * 299 + px[i * 4 + 1] * 587 + px[i * 4 + 2] * 114) ~/ 1000;
  }
  return Bitmap1.fromGray(w, h, gray);
}

/// The largest text that fits: the title (up to two lines) and then each
/// line on one line, smaller lines dropped from the end when even the
/// smallest size can't hold them all.
List<ui.Paragraph> _fitText(LabelContent content, double width, double height, int dpi) {
  final minPx = dpi * 1.6 / 25.4; // about 1.6 mm capitals: still readable
  final lines = content.lines.where((l) => l.trim().isNotEmpty).toList();
  ui.Paragraph para(String text, double px, {required bool bold, required int maxLines}) {
    final b = ui.ParagraphBuilder(ui.ParagraphStyle(
      maxLines: maxLines,
      ellipsis: '…',
      fontSize: px,
      fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w500,
      height: 1.1,
    ))
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000)))
      ..addText(text);
    return b.build()..layout(ui.ParagraphConstraints(width: width));
  }

  while (true) {
    for (var px = height * 0.45; px >= minPx; px *= 0.92) {
      final title = para(content.title, px, bold: true, maxLines: 2);
      final rest = [for (final l in lines) para(l, math.max(minPx, px * 0.72), bold: false, maxLines: 1)];
      final total = title.height + rest.fold(0.0, (a, p) => a + p.height);
      // Accept once everything fits and the title no longer needs an ellipsis
      // on one line (or we're at the smallest size).
      if (total <= height && (!title.didExceedMaxLines || px * 0.92 < minPx)) {
        return [title, ...rest];
      }
    }
    if (lines.isEmpty) return [para(content.title, minPx, bold: true, maxLines: 2)];
    lines.removeLast();
  }
}

/// A 1-bit picture as an image the UI can show (black on white).
Future<ui.Image> bitmapToImage(Bitmap1 b) async {
  final rgba = Uint8List(b.width * b.height * 4);
  for (var y = 0; y < b.height; y++) {
    for (var x = 0; x < b.width; x++) {
      final v = b.get(x, y) ? 0 : 255;
      final i = (y * b.width + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
      rgba[i + 3] = 255;
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer,
      width: b.width, height: b.height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}
