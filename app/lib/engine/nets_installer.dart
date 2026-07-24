import 'dart:io';

import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Reads a bundled asset's bytes. Injectable so [NetsInstaller.ensureInstalledTo]
/// is testable without the Flutter asset system.
typedef AssetReader = Future<ByteData> Function(String key);

/// Ensures the neural nets exist as real files on disk.
///
/// tract (the ONNX runtime inside wildbg) loads nets from filesystem paths, not
/// from memory, so Flutter assets — which live inside the app bundle — must be
/// materialised to a real directory before [EngineService.spawn] can point the
/// native engine at them.
class NetsInstaller {
  NetsInstaller._();

  /// Asset keys as declared in `pubspec.yaml` (`assets/nets/`).
  static const _assets = [
    'assets/nets/contact.onnx',
    'assets/nets/race.onnx',
  ];

  /// Relative path from a dev checkout root to the repo's production nets.
  static const _repoNetsRelative = 'native/wildbg-nets/neural-nets';

  /// How many parent directories to walk searching for the repo nets dir.
  static const _repoWalkUpLevels = 4;

  /// Copies the bundled nets into [targetDir], returning [targetDir]'s path.
  ///
  /// The directory is created recursively if missing. For each asset the
  /// destination filename is the asset's basename (e.g. `contact.onnx`). A copy
  /// is skipped when the destination already exists AND its length matches the
  /// asset's byte length — a cheap, good-enough freshness check that avoids
  /// rewriting ~1.5 MB on every launch. On any length mismatch (partial write,
  /// upgraded net) the file is overwritten.
  static Future<String> ensureInstalledTo(
      Directory targetDir, AssetReader readAsset) async {
    await targetDir.create(recursive: true);
    for (final assetKey in _assets) {
      final data = await readAsset(assetKey);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final dest = File(p.join(targetDir.path, p.basename(assetKey)));
      if (await dest.exists() && await dest.length() == bytes.length) {
        continue;
      }
      await dest.writeAsBytes(bytes, flush: true);
    }
    return targetDir.path;
  }

  /// Resolves a real nets directory for the running platform.
  ///
  /// On a desktop dev checkout (Windows/Linux/macOS) the repo already holds the
  /// production nets, so we use them in place — no copy — when
  /// `native/wildbg-nets/neural-nets` is found by walking up from
  /// [Directory.current] (up to [_repoWalkUpLevels] levels; the app runs from
  /// `app/`, tests from various depths). Otherwise (packaged desktop app, or
  /// Android/iOS where there is no checkout) the bundled assets are copied into
  /// the application-support directory via [getApplicationSupportDirectory].
  static Future<String> ensureInstalled() async {
    final repoDir = _findRepoNetsDir();
    if (repoDir != null) return repoDir.path;

    final support = await getApplicationSupportDirectory();
    final netsDir = Directory(p.join(support.path, 'nets'));
    return ensureInstalledTo(netsDir, rootBundle.load);
  }

  /// Walks up from [Directory.current] looking for the repo nets directory.
  /// Returns it only when it contains both nets; null otherwise.
  static Directory? _findRepoNetsDir() {
    var dir = Directory.current;
    for (var i = 0; i <= _repoWalkUpLevels; i++) {
      final candidate = Directory(p.join(dir.path, _repoNetsRelative));
      if (candidate.existsSync() &&
          File(p.join(candidate.path, 'contact.onnx')).existsSync() &&
          File(p.join(candidate.path, 'race.onnx')).existsSync()) {
        return candidate;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break; // reached filesystem root
      dir = parent;
    }
    return null;
  }
}
