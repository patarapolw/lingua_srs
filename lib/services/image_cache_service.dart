import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Keeps the online images of Markdown (notes, lessons) on disk, so they show
/// again without the network, after a restart, and without being fetched each
/// time Flutter's in-memory image cache lets go of them.
///
/// An image is stored under the hash of its URL the first time it is shown. A
/// URL is assumed to keep naming the same picture, like the audio cache does.
class ImageCacheService {
  ImageCacheService({
    http.Client? client,
    Future<Directory> Function()? directory,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _directory = directory ?? _defaultDirectory;

  /// The cache the app's Markdown views share. Tests replace it.
  static ImageCacheService instance = ImageCacheService();

  /// Largest image kept. A bigger response is shown from the network only.
  static const int maxBytes = 25 * 1024 * 1024;

  final http.Client _client;
  final Future<Directory> Function() _directory;
  final Duration timeout;
  final Map<String, Future<File?>> _pending = {};
  Directory? _resolvedDirectory;

  /// Whether [url] is one this cache can keep.
  static bool isCacheable(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// The file holding the image at [url]: the saved copy, else a download that
  /// is saved first. Null when the image cannot be had or kept; the caller
  /// then shows it from the network instead. A download several views ask for
  /// at once is made once.
  Future<File?> fetch(String url) {
    if (!isCacheable(url)) return Future.value();
    return _pending.putIfAbsent(
      url,
      // A block body: an arrow would return the removed future, which
      // whenComplete then waits for, and that is this very future.
      () => _load(url).whenComplete(() {
        _pending.remove(url);
      }),
    );
  }

  /// Forgets the saved copy of [url], e.g. because it does not decode.
  Future<void> evict(String url) async {
    try {
      final file = await _fileFor(url);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Could not evict cached image $url: $error');
    }
  }

  /// Deletes every saved image.
  Future<void> clear() async {
    try {
      final directory = await _ensureDirectory();
      await for (final entity in directory.list()) {
        if (entity is File) await entity.delete();
      }
    } catch (error) {
      debugPrint('Could not clear the image cache: $error');
    }
  }

  Future<File?> _load(String url) async {
    try {
      final file = await _fileFor(url);
      if (await file.exists() && await file.length() > 0) return file;

      final response = await _client
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          )
          .timeout(timeout);
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 ||
          bytes.isEmpty ||
          bytes.length > maxBytes ||
          !_isImageType(response.headers['content-type'])) {
        return null;
      }

      // Written aside and renamed, so a half-written file is never read.
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes);
      await temp.rename(file.path);
      return file;
    } catch (error) {
      debugPrint('Could not cache image $url: $error');
      return null;
    }
  }

  /// A page, JSON or an SVG (which Flutter cannot decode) is not kept as a
  /// picture. A missing type is trusted, and so is a generic binary one.
  static bool _isImageType(String? contentType) {
    if (contentType == null || contentType.trim().isEmpty) return true;
    final type = contentType.split(';').first.trim().toLowerCase();
    if (type.contains('svg')) return false;
    return type.startsWith('image/') || type == 'application/octet-stream';
  }

  Future<File> _fileFor(String url) async {
    final directory = await _ensureDirectory();
    final key = sha1.convert(utf8.encode(url)).toString();
    return File('${directory.path}${Platform.pathSeparator}$key');
  }

  Future<Directory> _ensureDirectory() async {
    final known = _resolvedDirectory;
    if (known != null) return known;
    final directory = await _directory();
    if (!await directory.exists()) await directory.create(recursive: true);
    return _resolvedDirectory = directory;
  }

  static Future<Directory> _defaultDirectory() async {
    Directory base;
    try {
      base = await getApplicationCacheDirectory();
    } catch (_) {
      base = await getApplicationSupportDirectory();
    }
    // Next to the audio cache.
    if (Platform.isWindows) {
      return Directory(
        '${Platform.environment['LOCALAPPDATA'] ?? base.path}'
        '${Platform.pathSeparator}cc.polv${Platform.pathSeparator}lingua.srs'
        '${Platform.pathSeparator}image_cache',
      );
    }
    return Directory('${base.path}${Platform.pathSeparator}image_cache');
  }
}
