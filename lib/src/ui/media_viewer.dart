import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/platform_io.dart' as platform;
import '../app/providers.dart';
import '../data/database.dart';
import '../data/model.dart';
import '../data/repository.dart';
import 'common.dart';

/// Full-size photos with pinch zoom, swiping between an item's media. Videos
/// and documents open in the platform's viewer.
class MediaViewer extends ConsumerStatefulWidget {
  const MediaViewer({super.key, required this.itemId, this.initialIndex = 0});
  final String itemId;
  final int initialIndex;

  @override
  ConsumerState<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends ConsumerState<MediaViewer> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaProvider(widget.itemId)).value ?? const <MediaEntry>[];
    final item = ref.watch(itemProvider(widget.itemId)).value;
    if (media.isEmpty) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.photo, title: 'No media'));
    }
    final index = _index.clamp(0, media.length - 1);
    final current = media[index];
    final store = ref.read(repositoryProvider).media;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${index + 1} of ${media.length}'),
        actions: [
          if (current.mediaKind == MediaKind.photo)
            IconButton(
              tooltip: 'Use as cover',
              icon: Icon(item?.coverMediaId == current.id ? Icons.star : Icons.star_border),
              onPressed: () => ref.read(repositoryProvider).setCover(widget.itemId, current.id),
            ),
          IconButton(
            tooltip: platform.isMobile ? 'Share or save' : 'Open in default app',
            icon: Icon(platform.isMobile ? Icons.ios_share : Icons.open_in_new),
            onPressed: () => platform.openExternally(store.fileFor(current)),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await confirm(context,
                  title: 'Delete this ${current.mediaKind.name}?',
                  message: 'The file is removed from this device.');
              if (!ok) return;
              await ref.read(repositoryProvider).deleteMedia(current);
              if (media.length == 1 && context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: media.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              final m = media[i];
              final file = store.fileFor(m);
              if (m.mediaKind == MediaKind.photo && file.existsSync()) {
                return InteractiveViewer(
                  maxScale: 8,
                  child: Center(
                    child: Image.file(
                      file,
                      errorBuilder: (_, _, _) => _OpenTile(media: m, onOpen: () => platform.openExternally(file)),
                    ),
                  ),
                );
              }
              return _OpenTile(media: m, onOpen: () => platform.openExternally(file));
            },
          ),
        ),
        _CaptionBar(key: ValueKey(current.id), media: current),
      ]),
    );
  }
}

class _OpenTile extends StatelessWidget {
  const _OpenTile({required this.media, required this.onOpen});
  final MediaEntry media;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          media.mediaKind == MediaKind.video ? Icons.movie_outlined : Icons.description_outlined,
          size: 72,
          color: Colors.white54,
        ),
        const SizedBox(height: 12),
        Text('${media.fileName.split('.').last.toUpperCase()} · ${media.sizeBytes.readableSize}',
            style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.play_arrow),
          label: Text(media.mediaKind == MediaKind.video ? 'Play' : 'Open'),
        ),
      ]),
    );
  }
}

class _CaptionBar extends ConsumerStatefulWidget {
  const _CaptionBar({super.key, required this.media});
  final MediaEntry media;

  @override
  ConsumerState<_CaptionBar> createState() => _CaptionBarState();
}

class _CaptionBarState extends ConsumerState<_CaptionBar> {
  late final _text = TextEditingController(text: widget.media.caption);
  // Read up front: ref can't be used in dispose(), where the caption is saved.
  late final Repository _repo;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(repositoryProvider);
  }

  @override
  void dispose() {
    _save();
    _text.dispose();
    super.dispose();
  }

  void _save() {
    if (_text.text != widget.media.caption) {
      _repo.updateCaption(widget.media.id, _text.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: TextField(
          controller: _text,
          style: const TextStyle(color: Colors.white),
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Add a note about this photo',
            hintStyle: TextStyle(color: Colors.white54),
            border: InputBorder.none,
          ),
          onEditingComplete: _save,
          onTapOutside: (_) => _save(),
        ),
      ),
    );
  }
}
