import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/image_cache_service.dart';

/// An online image in Markdown, kept on disk by [ImageCacheService].
///
/// The saved copy is shown when there is one, the image is downloaded and
/// saved when there is not, and when that is not possible (offline, not a
/// picture, a URL the cache does not handle) it is shown from the network
/// like any other image.
class CachedMarkdownImage extends StatefulWidget {
  final String url;

  const CachedMarkdownImage({super.key, required this.url});

  @override
  State<CachedMarkdownImage> createState() => _CachedMarkdownImageState();
}

class _CachedMarkdownImageState extends State<CachedMarkdownImage> {
  Future<File?>? _file;

  bool get _useCache => !kIsWeb && ImageCacheService.isCacheable(widget.url);

  @override
  void initState() {
    super.initState();
    _file = _useCache ? ImageCacheService.instance.fetch(widget.url) : null;
  }

  @override
  void didUpdateWidget(CachedMarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _file = _useCache ? ImageCacheService.instance.fetch(widget.url) : null;
    }
  }

  Widget _brokenImage() => const Icon(Icons.broken_image_outlined);

  Widget _fromNetwork() => Image.network(
    widget.url,
    errorBuilder: (context, error, stackTrace) => _brokenImage(),
  );

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) return _fromNetwork();
    return FutureBuilder<File?>(
      future: file,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final saved = snapshot.data;
        if (saved == null) return _fromNetwork();
        return Image.file(
          saved,
          errorBuilder: (context, error, stackTrace) {
            // A saved copy that does not decode would stay broken forever.
            unawaited(ImageCacheService.instance.evict(widget.url));
            return _brokenImage();
          },
        );
      },
    );
  }
}
