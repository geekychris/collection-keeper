import 'package:shared_preferences/shared_preferences.dart';

import '../labels/pdf_labels.dart';

/// Small per-device preferences: what was used last, so the walk-round
/// screens and the label printer pick up where they left off. Not synced.
class Settings {
  Settings(this._prefs);
  final SharedPreferences _prefs;

  static Future<Settings> load() async => Settings(await SharedPreferences.getInstance());

  String? get captureCollectionId => _prefs.getString('captureCollectionId');
  set captureCollectionId(String? v) => _set('captureCollectionId', v);

  String? get printerId => _prefs.getString('printerId');
  set printerId(String? v) => _set('printerId', v);

  String? get printerName => _prefs.getString('printerName');
  set printerName(String? v) => _set('printerName', v);

  String? get labelSizeId => _prefs.getString('labelSizeId');
  set labelSizeId(String? v) => _set('labelSizeId', v);

  int? get density => _prefs.getInt('density');
  set density(int? v) => v == null ? _prefs.remove('density') : _prefs.setInt('density', v);

  PdfLabelLayout get pdfLayout =>
      PdfLabelLayout.values.where((l) => l.name == _prefs.getString('pdfLayout')).firstOrNull ??
      PdfLabelLayout.a4;
  set pdfLayout(PdfLabelLayout v) => _prefs.setString('pdfLayout', v.name);

  void _set(String key, String? v) => v == null ? _prefs.remove(key) : _prefs.setString(key, v);
}
