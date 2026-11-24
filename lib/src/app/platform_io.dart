import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Phones and tablets have a camera and a share sheet; desktops have a file
/// system the user can see.
bool get isMobile => Platform.isIOS || Platform.isAndroid;

final _imagePicker = ImagePicker();

bool get canUseCamera => _imagePicker.supportsImageSource(ImageSource.camera);

/// On Android the app declares the camera permission (the label scanner
/// needs it), and then the system camera only opens once it is granted.
Future<void> _cameraAllowed() async {
  if (!Platform.isAndroid) return;
  final status = await Permission.camera.request();
  if (!status.isGranted) {
    throw const CameraDenied();
  }
}

class CameraDenied implements Exception {
  const CameraDenied();
  @override
  String toString() => 'Camera access is off. Allow it in Settings to take photos.';
}

Future<File?> takePhoto() async {
  await _cameraAllowed();
  final x = await _imagePicker.pickImage(source: ImageSource.camera);
  return x == null ? null : File(x.path);
}

Future<File?> recordVideo() async {
  await _cameraAllowed();
  final x = await _imagePicker.pickVideo(source: ImageSource.camera);
  return x == null ? null : File(x.path);
}

/// Photos and videos from the device's photo library.
Future<List<File>> pickFromLibrary() async {
  final picked = await _imagePicker.pickMultipleMedia();
  return [for (final x in picked) File(x.path)];
}

/// Any files from the file system (or Files on iOS).
Future<List<File>> pickFiles() async {
  final picked = await FilePicker.pickFiles(type: FileType.any);
  return [for (final f in picked) await _toFile(f)];
}

Future<File?> pickZip() async {
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['zip'],
  );
  return picked == null ? null : _toFile(picked);
}

Future<Directory?> pickDirectory({String? title}) async {
  final uri = await FilePicker.pickDirectory(dialogTitle: title);
  return uri == null || uri.scheme != 'file' ? null : Directory(uri.toFilePath());
}

/// A picked file may only be readable as a stream (Android content URIs), so
/// copy it to a temporary file in that case.
Future<File> _toFile(PlatformFile f) async {
  final path = f.path;
  if (path != null) return File(path);
  final dir = await Directory.systemTemp.createTemp('ck-pick-');
  final file = File(p.join(dir.path, f.name));
  return file.writeAsBytes(await f.readAsBytes(), flush: true);
}

/// Opens a file in the platform's viewer: the default app on desktop, the
/// share sheet ("Open in…", "Save to Files") on phones.
Future<void> openExternally(File file) async {
  if (isMobile) {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  } else {
    await launchUrl(Uri.file(file.path));
  }
}
