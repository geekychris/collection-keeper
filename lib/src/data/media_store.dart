import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'model.dart';

/// Makes a JPEG thumbnail for a media file, or returns null when it can't.
typedef Thumbnailer = Future<Uint8List?> Function(File source, MediaKind kind);

class StoredFile {
  StoredFile({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
  });
  final String fileName;
  final int sizeBytes;
  final String sha256;
}

/// Full-size media files and their thumbnails, kept under one directory:
/// `<root>/<media id>.<ext>` and `<root>/thumbs/<media id>.jpg`.
class MediaStore {
  MediaStore(this.root, {Thumbnailer? thumbnailer})
      : _thumbnailer = thumbnailer ?? platformThumbnail;

  final Directory root;
  final Thumbnailer _thumbnailer;

  static Future<MediaStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'media'));
    await root.create(recursive: true);
    return MediaStore(root);
  }

  File fileFor(MediaEntry media) => File(p.join(root.path, media.fileName));

  File thumbnailFor(String mediaId) =>
      File(p.join(root.path, 'thumbs', '$mediaId.jpg'));

  /// Copies [source] into the store as the file for media [id], then makes
  /// its thumbnail. The source is copied, never moved: it may belong to the
  /// photo picker or to the user.
  Future<StoredFile> add(File source, String id, MediaKind kind) async {
    var ext = p.extension(source.path).toLowerCase();
    if (ext.isEmpty) ext = kind == MediaKind.video ? '.mov' : '.jpg';
    final fileName = '$id$ext';
    final dest = File(p.join(root.path, fileName));
    await source.copy(dest.path);
    final digest = await sha256.bind(dest.openRead()).first;
    await makeThumbnail(id, dest, kind);
    return StoredFile(
      fileName: fileName,
      sizeBytes: await dest.length(),
      sha256: digest.toString(),
    );
  }

  /// (Re)makes the thumbnail for media [id]. Failures leave no thumbnail and
  /// the UI falls back to an icon.
  Future<void> makeThumbnail(String id, File source, MediaKind kind) async {
    final bytes = await _thumbnailer(source, kind);
    if (bytes == null) return;
    final thumb = thumbnailFor(id);
    await thumb.parent.create(recursive: true);
    await thumb.writeAsBytes(bytes, flush: true);
  }

  Future<void> remove(MediaEntry media) async {
    for (final f in [fileFor(media), thumbnailFor(media.id)]) {
      if (await f.exists()) await f.delete();
    }
  }
}

const _thumbnailEdge = 480;

/// Decodes photos with the platform's own codecs (so HEIC works on Apple
/// platforms and Android), honouring EXIF orientation, and scales the longest
/// edge to 480 px without changing the aspect ratio.
Future<Uint8List?> platformThumbnail(File source, MediaKind kind) async {
  if (kind != MediaKind.photo) return null;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await source.readAsBytes());
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        final scale = math.min(1.0, _thumbnailEdge / math.max(w, h));
        // Giving only one dimension keeps the aspect ratio.
        return w >= h
            ? ui.TargetImageSize(width: (w * scale).round())
            : ui.TargetImageSize(height: (h * scale).round());
      },
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width, height = image.height;
    image.dispose();
    codec.dispose();
    if (rgba == null) return null;
    final pixels = rgba.buffer.asUint8List();
    return await Isolate.run(() {
      final decoded = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: pixels.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      return img.encodeJpg(decoded, quality: 82);
    });
  } catch (_) {
    return null;
  }
}
