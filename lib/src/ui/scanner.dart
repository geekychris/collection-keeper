import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Whether this device can scan with a camera (the scanner plugin covers
/// iOS, Android and macOS; Windows uses typed codes or a USB scanner).
bool get cameraScanning => Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

/// A camera viewfinder that reports each code it reads, with a field below
/// for typing a code, or for a USB or Bluetooth barcode scanner that types
/// like a keyboard. The same code is reported again only after a pause, so
/// holding the phone over a label doesn't repeat it.
class CodeScanner extends StatefulWidget {
  const CodeScanner({super.key, required this.onCode, this.hint = 'Type or scan a code', this.camera});
  final Future<void> Function(String code) onCode;
  final String hint;

  /// Show the camera; defaults to [cameraScanning]. Tests turn it off.
  final bool? camera;

  @override
  State<CodeScanner> createState() => _CodeScannerState();
}

class _CodeScannerState extends State<CodeScanner> {
  late final bool _camera = widget.camera ?? cameraScanning;
  MobileScannerController? _controller;
  final _text = TextEditingController();
  final _focus = FocusNode();
  String? _last;
  DateTime _lastAt = DateTime(0);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_camera) {
      _controller = MobileScannerController(
        formats: const [BarcodeFormat.qrCode, BarcodeFormat.dataMatrix, BarcodeFormat.code128],
        detectionSpeed: DetectionSpeed.normal,
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _handle(String raw) async {
    final code = raw.trim();
    if (code.isEmpty || _busy) return;
    final now = DateTime.now();
    if (code == _last && now.difference(_lastAt) < const Duration(seconds: 3)) return;
    _last = code;
    _lastAt = now;
    setState(() => _busy = true);
    try {
      await widget.onCode(code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      if (_controller != null)
        Expanded(
          child: ClipRect(
            child: Stack(fit: StackFit.expand, children: [
              MobileScanner(
                controller: _controller,
                onDetect: (capture) {
                  final value = capture.barcodes.map((b) => b.rawValue).nonNulls.firstOrNull;
                  if (value != null) _handle(value);
                },
                errorBuilder: (context, error) => Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? 'Camera access is off. Allow it in Settings to scan labels, '
                            'or type codes below.'
                        : 'The camera isn’t available (${error.errorCode.name}). Type codes below.',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              if (_busy) const Center(child: CircularProgressIndicator()),
              Positioned(
                right: 8,
                top: 8,
                child: IconButton.filledTonal(
                  tooltip: 'Torch',
                  icon: const Icon(Icons.flashlight_on_outlined),
                  onPressed: () => _controller?.toggleTorch(),
                ),
              ),
            ]),
          ),
        ),
      Material(
        color: scheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _text,
                focusNode: _focus,
                autofocus: !_camera,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  prefixIcon: const Icon(Icons.keyboard_outlined),
                  border: InputBorder.none,
                ),
                textInputAction: TextInputAction.go,
                onSubmitted: (v) async {
                  _last = null; // a typed code always counts
                  await _handle(v);
                  _text.clear();
                  _focus.requestFocus();
                },
              ),
            ),
            IconButton(
              tooltip: 'Look up',
              icon: const Icon(Icons.arrow_forward),
              onPressed: () async {
                _last = null;
                await _handle(_text.text);
                _text.clear();
              },
            ),
          ]),
        ),
      ),
    ]);
  }
}
