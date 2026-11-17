import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The root directory of the dependency [name], from the package config
/// that `flutter pub get` writes.
Directory packageRoot(String name) {
  final configFile = File('.dart_tool/package_config.json');
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final package = (config['packages'] as List).cast<Map>().firstWhere(
    (p) => p['name'] == name,
  );
  final root = configFile.absolute.uri.resolve(package['rootUri'] as String);
  return Directory.fromUri(root);
}

/// `name` in [section] of a Cargo.toml, or null when it has none.
String? cargoName(String toml, String section) {
  String? current;
  for (final line in const LineSplitter().convert(toml)) {
    final header = RegExp(r'^\s*\[([^\]]+)\]').firstMatch(line);
    if (header != null) {
      current = header.group(1);
      continue;
    }
    if (current != section) continue;
    final name = RegExp(r'^\s*name\s*=\s*"([^"]+)"').firstMatch(line);
    if (name != null) return name.group(1);
  }
  return null;
}

void main() {
  // Rust plugins built by native_toolchain_rust (1.0.5 and later) name the
  // Android library after the crate's `[lib] name`, or its package name when
  // it has none, and their Java code loads it with System.loadLibrary. If the
  // two differ, the plugin can't load on Android and, for
  // super_native_extensions, clipboard paste fails (#255). On 2026-11-14 a
  // `[lib] name` added by hand to the pub cache's copy did exactly that; it
  // only silenced a harmless "Failed to find lib.name" SEVERE log.
  const plugins = {
    'super_native_extensions': (
      cargo: 'rust/Cargo.toml',
      java:
          'android/src/main/java/com/superlist/super_native_extensions/'
          'SuperNativeExtensionsPlugin.java',
    ),
    'irondash_engine_context': (
      cargo: 'android/rust/Cargo.toml',
      java:
          'android/src/main/java/dev/irondash/engine_context/'
          'IrondashEngineContextPlugin.java',
    ),
  };

  for (final MapEntry(key: name, value: files) in plugins.entries) {
    test('$name builds the Android library its Java code loads', () {
      final root = packageRoot(name);
      final toml = File.fromUri(root.uri.resolve(files.cargo));
      final java = File.fromUri(root.uri.resolve(files.java));
      final cargo = toml.readAsStringSync();
      final built = cargoName(cargo, 'lib') ?? cargoName(cargo, 'package');
      final loaded = RegExp(r'System\.loadLibrary\("([^"]+)"\)')
          .firstMatch(java.readAsStringSync())
          ?.group(1);

      expect(loaded, isNotNull, reason: 'No loadLibrary call in ${java.path}');
      expect(
        built,
        loaded,
        reason:
            '${toml.path} builds lib$built.so, but Android loads '
            'lib$loaded.so. If the pub cache copy was edited, restore it '
            '(`dart pub cache repair`); otherwise see #255.',
      );
    });
  }
}
