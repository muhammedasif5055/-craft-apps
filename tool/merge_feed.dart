import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Turns the release's zips into `feed.json`. This is the only writer of the
/// feed: the workflow runs it, a person can run it locally, and the launcher
/// never does.
///
/// Lives in the public craft-apps repo, so it keeps to two dependencies and
/// imports nothing from the launcher.
class MergeException implements Exception {
  MergeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A release asset as the workflow downloaded it.
typedef ZipInput = ({String fileName, List<int> bytes});

/// `<app-id>-<version>-<os>-<arch>.zip`; the id may itself contain dashes, so
/// the id is matched lazily and the version has to start with a digit.
final _namePattern = RegExp(
  r'^(?<id>.+?)-(?<version>\d[0-9A-Za-z.+_-]*)-'
  r'(?<os>windows|macos|linux)-(?<arch>x64|arm64)\.zip$',
  caseSensitive: false,
);
final _versionPattern = RegExp(r'^\d+(\.\d+)*([-+][0-9A-Za-z.+_-]+)?$');

/// Fields an `apps/<id>.json` may override on the feed entry.
const _descriptive = [
  'name',
  'tagline',
  'kind',
  'publisher',
  'color',
  'ink_light',
  'ink_dark',
  'details',
];

({String id, String version, String os, String arch})? parseAssetName(
  String fileName,
) {
  final match = _namePattern.firstMatch(fileName);
  if (match == null) return null;
  return (
    id: match.namedGroup('id')!,
    version: match.namedGroup('version')!,
    os: match.namedGroup('os')!.toLowerCase(),
    arch: match.namedGroup('arch')!.toLowerCase(),
  );
}

/// Adds [zips] as [tag]'s assets, keeping every earlier release in place so a
/// rollback still has a version to go back to.
///
/// A published version's digest is final: re-uploading different bytes for it
/// throws instead of silently changing what other machines already installed.
({Map<String, Object?> feed, List<String> added}) mergeRelease({
  required Map<String, dynamic> feed,
  required String tag,
  required List<ZipInput> zips,
  required String downloadBase,
  Map<String, Map<String, dynamic>> metadata = const {},
  String notes = '',
  DateTime? publishedAt,
}) {
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  if (!_versionPattern.hasMatch(version)) {
    throw MergeException('tag "$tag" is not a version: name releases v1.2.3');
  }
  if (zips.isEmpty) throw MergeException('no zips to publish for $tag');

  final apps = <String, Map<String, dynamic>>{};
  for (final raw in (feed['apps'] as List? ?? const [])) {
    final app = raw as Map<String, dynamic>;
    apps[app['id'] as String] = app;
  }

  final added = <String>[];
  for (final zip in zips) {
    final parsed = parseAssetName(zip.fileName);
    if (parsed == null) {
      throw MergeException('"${zip.fileName}" is not '
          '<app-id>-<version>-<os>-<arch>.zip');
    }
    if (parsed.version != version) {
      throw MergeException('"${zip.fileName}" names ${parsed.version} but the '
          'release is $version');
    }

    final meta = metadata[parsed.id];
    final app = apps.putIfAbsent(
      parsed.id,
      () => <String, dynamic>{'id': parsed.id, 'releases': <dynamic>[]},
    );
    if (meta != null) {
      for (final key in _descriptive) {
        if (meta.containsKey(key)) app[key] = meta[key];
      }
    }
    app['name'] ??= _titleCase(parsed.id);

    final release = _releaseFor(
      app,
      version,
      meta?['track'] as String? ?? 'stable',
      notes,
      publishedAt,
    );
    final assets = release['assets'] as List<dynamic>;
    final asset = <String, dynamic>{
      'os': parsed.os,
      'arch': parsed.arch,
      'url': '$downloadBase/$tag/${zip.fileName}',
      'sha256': sha256.convert(zip.bytes).toString(),
      'size_bytes': zip.bytes.length,
      'executable': _executable(zip, parsed.os, parsed.arch, meta),
    };

    final previous = assets.cast<Map<String, dynamic>>().where(
          (a) => a['os'] == parsed.os && a['arch'] == parsed.arch,
        );
    if (previous.isEmpty) {
      assets.add(asset);
      added.add('${parsed.id} $version ${parsed.os}/${parsed.arch}');
    } else if (previous.first['sha256'] != asset['sha256']) {
      throw MergeException(
        '${parsed.id} $version ${parsed.os}/${parsed.arch}: the asset changed. '
        'A published version is immutable: bump the version instead.',
      );
    }
  }

  return (
    feed: <String, Object?>{
      'schema': 1,
      'apps': [for (final app in apps.values) app],
    },
    added: added,
  );
}

Map<String, dynamic> _releaseFor(
  Map<String, dynamic> app,
  String version,
  String track,
  String notes,
  DateTime? publishedAt,
) {
  final releases = app['releases'] as List<dynamic>;
  for (final raw in releases) {
    final release = raw as Map<String, dynamic>;
    if (release['version'] != version) continue;
    if (notes.isNotEmpty) release['notes_markdown'] = notes;
    return release;
  }
  final release = <String, dynamic>{
    'version': version,
    'track': track,
    'published_at': (publishedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'notes_markdown': notes,
    'assets': <dynamic>[],
  };
  releases.add(release);
  return release;
}

/// The binary to launch, relative to the unpacked version folder: the zip's
/// single root file, unless `apps/<id>.json` names it per platform.
String _executable(
  ZipInput zip,
  String os,
  String arch,
  Map<String, dynamic>? meta,
) {
  final named = (meta?['executables'] as Map?)?['$os-$arch'];
  if (named is String && named.isNotEmpty) return named;

  final roots = _rootFiles(zip.bytes);
  final candidates = os == 'windows'
      ? roots.where((name) => name.toLowerCase().endsWith('.exe')).toList()
      : roots;
  if (candidates.length == 1) return candidates.single;
  throw MergeException(
    '${zip.fileName}: cannot tell what to launch '
    '(${candidates.isEmpty ? 'nothing at the zip root' : candidates.join(', ')}). '
    'Set "executables": {"$os-$arch": "name"} in apps/<id>.json',
  );
}

List<String> _rootFiles(List<int> bytes) => [
      for (final file in ZipDecoder().decodeBytes(bytes).files)
        if (file.isFile && !file.name.contains('/')) file.name,
    ];

String _titleCase(String id) => id
    .split('-')
    .where((word) => word.isNotEmpty)
    .map((word) => word[0].toUpperCase() + word.substring(1))
    .join(' ');

const _usage = '''
feeds the release zips into feed.json
  --tag <v1.2.3>           release tag (required)
  --assets <dir>           where the zips were downloaded (default: assets)
  --feed <file>            the feed to update (default: feed.json)
  --apps <dir>             per-app metadata (default: apps)
  --notes <file>           release notes markdown
  --published-at <iso8601> release date (default: now)
  --download-base <url>    asset URL prefix (default: this repo's release
                           downloads, from GITHUB_REPOSITORY in Actions)''';

Future<void> main(List<String> args) async {
  try {
    final options = _options(args);
    if (options == null) {
      stdout.writeln(_usage);
      exit(64);
    }
    final tag = options['tag'];
    if (tag == null) throw MergeException('--tag is required (e.g. v1.2.3)');

    final feedFile = File(options['feed'] ?? 'feed.json');
    final feed = await feedFile.exists()
        ? jsonDecode(await feedFile.readAsString()) as Map<String, dynamic>
        : <String, dynamic>{'schema': 1, 'apps': <dynamic>[]};

    final zips = <ZipInput>[];
    await for (final entity
        in Directory(options['assets'] ?? 'assets').list()) {
      if (entity is File && entity.path.toLowerCase().endsWith('.zip')) {
        zips.add((
          fileName: entity.uri.pathSegments.last,
          bytes: await entity.readAsBytes(),
        ));
      }
    }
    zips.sort((a, b) => a.fileName.compareTo(b.fileName));

    final metadata = <String, Map<String, dynamic>>{};
    final appsDir = Directory(options['apps'] ?? 'apps');
    if (await appsDir.exists()) {
      await for (final entity in appsDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final id = entity.uri.pathSegments.last.replaceAll('.json', '');
          metadata[id] =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        }
      }
    }

    final notesFile = options['notes'];
    final result = mergeRelease(
      feed: feed,
      tag: tag,
      zips: zips,
      downloadBase: options['download-base'] ?? _downloadBase(),
      metadata: metadata,
      notes: notesFile == null ? '' : (await File(notesFile).readAsString()).trim(),
      publishedAt: DateTime.tryParse(options['published-at'] ?? ''),
    );
    await feedFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(result.feed)}\n',
      flush: true,
    );
    stdout.writeln(result.added.isEmpty
        ? 'feed unchanged for $tag'
        : 'added: ${result.added.join(', ')}');
  } on MergeException catch (error) {
    stderr.writeln('feed refused: ${error.message}');
    exit(1);
  }
}

String _downloadBase() {
  final repo = Platform.environment['GITHUB_REPOSITORY'];
  if (repo == null || repo.isEmpty) {
    throw MergeException('--download-base is required outside Actions '
        '(e.g. https://github.com/you/craft-apps/releases/download)');
  }
  return 'https://github.com/$repo/releases/download';
}

Map<String, String>? _options(List<String> args) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--') || i + 1 >= args.length) return null;
    values[arg.substring(2)] = args[++i];
  }
  return values;
}
