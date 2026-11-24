import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../data/model.dart';

/// Width at which screens switch to side-by-side panes.
const wideLayoutWidth = 900.0;

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wideLayoutWidth;

/// A media thumbnail, or an icon when there is none (videos, documents, or a
/// photo the platform could not decode).
class MediaThumb extends ConsumerWidget {
  const MediaThumb({
    super.key,
    required this.mediaId,
    this.kind = MediaKind.photo,
    this.size = 56,
    this.radius = 8,
  });

  final String? mediaId;
  final MediaKind kind;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder() => Container(
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(
            switch (kind) {
              MediaKind.photo => Icons.photo_outlined,
              MediaKind.video => Icons.videocam_outlined,
              MediaKind.document => Icons.description_outlined,
            },
            color: scheme.onSurfaceVariant,
            size: size * 0.4,
          ),
        );
    Widget child = placeholder();
    if (mediaId != null) {
      final file = ref.watch(repositoryProvider).media.thumbnailFor(mediaId!);
      if (file.existsSync()) {
        child = Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (_, _, _) => placeholder(),
        );
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(dimension: size, child: child),
    );
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Delete',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [task], showing a blocking progress dialog and reporting failures.
Future<T?> withProgress<T>(BuildContext context, String label, Future<T> Function() task) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Flexible(child: Text(label)),
        ]),
      ),
    ),
  );
  try {
    return await task();
  } catch (e) {
    if (context.mounted) showMessage(context, 'Failed: $e');
    return null;
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      ),
    );
  }
}

/// Shows an AsyncValue's data, a spinner while loading, and the error if any.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      );
}

extension FileSize on int {
  String get readableSize {
    if (this < 1024) return '$this B';
    if (this < 1024 * 1024) return '${(this / 1024).toStringAsFixed(0)} KB';
    if (this < 1024 * 1024 * 1024) return '${(this / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(this / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

File? existingFile(File f) => f.existsSync() ? f : null;
