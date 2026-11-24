import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'label.dart';

/// How labels are laid out in a PDF for an ordinary printer.
enum PdfLabelLayout {
  /// One label per page at the label's size, for label printers with a
  /// system driver (Brother, Dymo, Zebra…).
  roll('One label per page (label printer)'),

  /// A grid on A4 paper, for sticker sheets or paper and tape.
  a4('Sheet of labels, A4'),

  /// A grid on US Letter paper.
  letter('Sheet of labels, Letter');

  const PdfLabelLayout(this.label);
  final String label;
}

/// A PDF of [labels], each [size] (mm) with the QR code on the left and the
/// text beside it. The QR code is drawn as vectors, so it stays sharp at any
/// printer resolution.
Future<Uint8List> labelsPdf(List<LabelContent> labels, LabelSize size, PdfLabelLayout layout) async {
  // Noto Sans (bundled, so it works offline) covers accents and the "›" in
  // location paths, which the PDF standard fonts don't.
  final theme = pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf')),
  );
  final doc = pw.Document(title: 'Labels', creator: 'Collection Keeper', theme: theme);
  final w = size.w * PdfPageFormat.mm, h = size.h * PdfPageFormat.mm;

  pw.Widget label(LabelContent c) {
    final pad = 1.2 * PdfPageFormat.mm;
    final qr = (h - 2 * pad).clamp(0.0, w * 0.55);
    return pw.Container(
      width: w,
      height: h,
      padding: pw.EdgeInsets.all(pad),
      child: pw.Row(children: [
        pw.BarcodeWidget(
          barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium),
          data: c.code,
          width: qr,
          height: qr,
          drawText: false,
        ),
        pw.SizedBox(width: pad),
        pw.Expanded(
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(c.title,
                  maxLines: 2,
                  style: pw.TextStyle(fontSize: (h * 0.22).clamp(5, 14), fontWeight: pw.FontWeight.bold)),
              for (final line in c.lines.where((l) => l.trim().isNotEmpty))
                pw.Text(line, maxLines: 1, style: pw.TextStyle(fontSize: (h * 0.15).clamp(4, 9))),
            ],
          ),
        ),
      ]),
    );
  }

  if (layout == PdfLabelLayout.roll) {
    for (final c in labels) {
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, h),
        build: (_) => label(c),
      ));
    }
  } else {
    final format = layout == PdfLabelLayout.a4 ? PdfPageFormat.a4 : PdfPageFormat.letter;
    final margin = 10 * PdfPageFormat.mm;
    final gap = 2 * PdfPageFormat.mm;
    final cols = ((format.width - 2 * margin + gap) / (w + gap)).floor().clamp(1, 20);
    final rows = ((format.height - 2 * margin + gap) / (h + gap)).floor().clamp(1, 40);
    final perPage = cols * rows;
    for (var start = 0; start < labels.length; start += perPage) {
      final chunk = labels.sublist(start, (start + perPage).clamp(0, labels.length));
      doc.addPage(pw.Page(
        pageFormat: format.copyWith(
            marginLeft: margin, marginRight: margin, marginTop: margin, marginBottom: margin),
        build: (_) => pw.Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in chunk)
              pw.Container(
                decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey400, width: 0.3)),
                child: label(c),
              ),
          ],
        ),
      ));
    }
  }
  return doc.save();
}
