import 'dart:convert';
import 'dart:io';

/// Run: `dart tool/check.dart [<repository>]`
///
/// Checks the metadata of a corpus repository against its git tree. In a repository of
/// vendored sources: `sources.json`, `corpus.json`, `candidates.json`, `rosetta/manifest.json`
/// and each source's `manifest.json`. In a snippet collection: `manifest.json`, `held.json` and
/// `LICENSES.md`. Each file a manifest lists must be in the tree as the blob the manifest names,
/// and the tree must hold nothing a manifest does not list, so the check reads only `git
/// ls-tree` and the manifests themselves: a blobless clone with the manifests checked out is
/// enough, and nothing is fetched. Exits 1 when anything is wrong.
Future<void> main(List<String> args) async {
  if (args.length > 1 || args.contains('--help') || args.contains('-h')) {
    stderr.writeln('usage: dart tool/check.dart [<repository>]');
    exitCode = 2;
    return;
  }
  final root = Directory(args.isEmpty ? '${File.fromUri(Platform.script).parent.path}/..' : args.single).absolute;
  final check = Check(root, await readTree(root));
  if (check.tree.containsKey('sources.json')) {
    check.sourcesRepository();
  } else if (check.tree.containsKey('manifest.json')) {
    check.snippetCollection();
  } else {
    check.problem('.', 'neither a sources.json nor a manifest.json: not a corpus repository');
  }
  check.notes.forEach(stdout.writeln);
  for (final line in check.problems) {
    stdout.writeln('PROBLEM $line');
  }
  stdout.writeln('${check.problems.length} problems');
  if (check.problems.isNotEmpty) exitCode = 1;
}

/// Every blob of `HEAD` by path, with its object id.
Future<Map<String, String>> readTree(Directory root) async {
  final result = await Process.run('git', ['-C', root.path, 'ls-tree', '-r', '-z', 'HEAD'], stdoutEncoding: utf8);
  if (result.exitCode != 0) throw StateError('git ls-tree failed: ${result.stderr}');
  final tree = <String, String>{};
  for (final record in (result.stdout as String).split('\x00')) {
    final tab = record.indexOf('\t');
    if (tab < 0) continue;
    final meta = record.substring(0, tab).split(' ');
    if (meta.length == 3 && meta[1] == 'blob') tree[record.substring(tab + 1)] = meta[2];
  }
  return tree;
}

final RegExp _sha40 = RegExp(r'^[0-9a-f]{40}$');
final RegExp _sha64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _ownerRepo = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The files a source directory holds beside those its manifest lists.
const Set<String> sourceExtras = {'manifest.json', 'LICENSE.md', 'vi-package-manifest.json'};

class Check {
  Check(this.root, this.tree);

  final Directory root;

  /// Blob ids by path.
  final Map<String, String> tree;

  final List<String> problems = [];

  final List<String> notes = [];

  void problem(String path, String message) => problems.add('$path: $message');

  File file(String path) => File('${root.path}/$path');

  Iterable<String> under(String prefix) sync* {
    for (final path in tree.keys) {
      if (path.startsWith(prefix)) yield path.substring(prefix.length);
    }
  }

  Set<String> directoriesUnder(String prefix) => {
    for (final path in under(prefix))
      if (path.contains('/')) path.substring(0, path.indexOf('/')),
  };

  Object? readJson(String path) {
    if (!tree.containsKey(path)) {
      problem(path, 'missing from the tree');
      return null;
    }
    if (!file(path).existsSync()) {
      problem(path, 'not checked out');
      return null;
    }
    try {
      return jsonDecode(file(path).readAsStringSync());
    } on FormatException catch (e) {
      problem(path, 'not JSON: ${e.message}');
      return null;
    }
  }

  List<Map<String, dynamic>>? jsonList(String path, Object? json) {
    if (json is! List) {
      if (json != null) problem(path, 'expected a list');
      return null;
    }
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < json.length; i++) {
      if (json[i] case final Map<String, dynamic> entry) {
        out.add(entry);
      } else {
        problem(path, 'entry $i is not an object');
      }
    }
    return out;
  }

  String _at(Map<String, dynamic> entry) {
    final id = entry['name'] ?? entry['file'] ?? entry['path'] ?? entry['repo'];
    return id == null ? '' : ' in entry "$id"';
  }

  String? string(String path, Map<String, dynamic> entry, String key, {RegExp? pattern, bool required = true}) {
    final value = entry[key];
    if (value == null) {
      if (required) problem(path, 'missing "$key"${_at(entry)}');
      return null;
    }
    if (value is! String || value.isEmpty) {
      problem(path, '"$key" is not a non-empty string${_at(entry)}');
      return null;
    }
    if (pattern != null && !pattern.hasMatch(value)) {
      problem(path, '"$key" is "$value", not ${pattern.pattern}${_at(entry)}');
      return null;
    }
    return value;
  }

  int? integer(String path, Map<String, dynamic> entry, String key) {
    final value = entry[key];
    if (value is int && value >= 0) return value;
    problem(path, '"$key" is not a non-negative integer${_at(entry)}');
    return null;
  }

  void url(String path, Map<String, dynamic> entry, String key, {bool required = true}) {
    final value = string(path, entry, key, required: required);
    if (value == null) return;
    final uri = Uri.tryParse(value);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      problem(path, '"$key" is not an http(s) URL: $value${_at(entry)}');
    }
  }

  /// The listed file at [treePath] is in the tree as the blob the manifest names.
  void blob(String manifest, Map<String, dynamic> entry, String treePath) {
    final expected = string(manifest, entry, 'blob', pattern: _sha40);
    final actual = tree[treePath];
    if (actual == null) {
      problem(treePath, 'listed in $manifest but missing from the tree');
    } else if (expected != null && actual != expected) {
      problem(treePath, 'is blob $actual, $manifest says $expected');
    }
  }

  // ----- a repository of vendored sources -----

  void sourcesRepository() {
    final keep = _corpusJson();
    final sources = _sourcesJson();
    _candidatesJson();
    _rosetta();
    if (sources == null) return;
    final names = {for (final source in sources) source['name'] as String};
    final dirs = directoriesUnder('sources/');
    for (final name in dirs.difference(names)) {
      problem('sources/$name', 'not listed in sources.json');
    }
    for (final name in names.difference(dirs)) {
      problem('sources.json', 'source "$name" has no directory under sources/');
    }
    for (final source in sources) {
      final name = source['name'] as String;
      if (!dirs.contains(name)) continue;
      final dir = 'sources/$name';
      for (final required in ['manifest.json', 'LICENSE.md']) {
        if (!tree.containsKey('$dir/$required')) problem('$dir/$required', 'missing from the tree');
      }
      _source(dir, source, keep);
    }
    notes.add('${sources.length} sources checked');
  }

  List<String>? _corpusJson() {
    final json = readJson('corpus.json');
    if (json == null) return null;
    if (json is! Map<String, dynamic> || json['keep'] is! List) {
      problem('corpus.json', 'expected an object with a "keep" list');
      return null;
    }
    final keep = <String>[];
    for (final extension in json['keep'] as List) {
      if (extension is String &&
          extension.startsWith('.') &&
          extension.length > 1 &&
          extension == extension.toLowerCase()) {
        keep.add(extension);
      } else {
        problem('corpus.json', '"keep" entry $extension is not a lower-case extension with its dot');
      }
    }
    if (json['budget'] case final budget? when budget is! int) problem('corpus.json', '"budget" is not an integer');
    return keep;
  }

  List<Map<String, dynamic>>? _sourcesJson() {
    final list = jsonList('sources.json', readJson('sources.json'));
    if (list == null) return null;
    final seen = <String>{};
    String? previous;
    for (final entry in list) {
      final name = string('sources.json', entry, 'name');
      final repo = string('sources.json', entry, 'repo', pattern: _ownerRepo);
      string('sources.json', entry, 'commit', pattern: _sha40);
      string('sources.json', entry, 'license');
      integer('sources.json', entry, 'files');
      integer('sources.json', entry, 'bytes');
      if (name == null) continue;
      if (repo != null && name != repo.replaceAll('/', '__')) {
        problem('sources.json', 'source "$name" is not named after its repo "$repo"');
      }
      if (!seen.add(name)) problem('sources.json', 'source "$name" is listed twice');
      if (previous != null && previous.compareTo(name) > 0) problem('sources.json', 'source "$name" is out of order');
      previous = name;
    }
    return [
      for (final entry in list)
        if (entry['name'] is String) entry,
    ];
  }

  void _candidatesJson() {
    if (!tree.containsKey('candidates.json')) return;
    final list = jsonList('candidates.json', readJson('candidates.json'));
    if (list == null) return;
    for (final entry in list) {
      string('candidates.json', entry, 'repo', pattern: _ownerRepo);
      string('candidates.json', entry, 'commit', pattern: _sha40);
      string('candidates.json', entry, 'reason');
    }
  }

  void _rosetta() {
    const path = 'rosetta/manifest.json';
    if (!directoriesUnder('').contains('rosetta')) return;
    final list = jsonList(path, readJson(path));
    if (list == null) return;
    final listed = <String>{};
    for (final entry in list) {
      final name = string(path, entry, 'file');
      string(path, entry, 'repo', pattern: _ownerRepo);
      url(path, entry, 'url');
      string(path, entry, 'commit', pattern: _sha40);
      string(path, entry, 'path');
      string(path, entry, 'sha256', pattern: _sha64);
      string(path, entry, 'license');
      if (name == null) continue;
      if (!listed.add(name)) problem(path, '"$name" is listed twice');
      blob(path, entry, 'rosetta/$name');
    }
    for (final name in under('rosetta/')) {
      if (name != 'manifest.json' && !listed.contains(name)) {
        problem('rosetta/$name', 'not listed in rosetta/manifest.json');
      }
    }
  }

  void _source(String dir, Map<String, dynamic> source, List<String>? keep) {
    final path = '$dir/manifest.json';
    final json = readJson(path);
    if (json is! Map<String, dynamic>) {
      if (json != null) problem(path, 'expected an object');
      return;
    }
    for (final key in ['repo', 'commit', 'license']) {
      if (json[key] != source[key]) problem(path, '"$key" is ${json[key]}, sources.json says ${source[key]}');
    }
    if (json['url'] != 'https://github.com/${source['repo']}') problem(path, '"url" is not the repo on GitHub');
    string(path, json, 'licenseFile');
    string(path, json, 'fetched', pattern: _isoDate);
    if (json['skipped'] is! List) problem(path, '"skipped" is not a list');
    if (json['external'] is! List) problem(path, '"external" is not a list');
    if (!json.containsKey('files')) problem(path, 'missing "files"');
    final files = jsonList(path, json['files']);
    if (files == null) return;
    final listed = <String>{};
    var bytes = 0;
    for (final entry in files) {
      final relative = string(path, entry, 'path');
      final size = integer(path, entry, 'bytes');
      string(path, entry, 'sha256', pattern: _sha64);
      final via = string(path, entry, 'via');
      if (relative == null || size == null) continue;
      if (!listed.add(relative)) problem(path, '"$relative" is listed twice');
      bytes += size;
      if (via != null && via != 'extension' && via != 'tree' && !via.startsWith('ref:')) {
        problem(path, '"via" of "$relative" is "$via", not extension, tree or ref:<path>');
      }
      if (via == 'extension' && keep != null && !keep.any(relative.toLowerCase().endsWith)) {
        problem(path, '"$relative" was kept for its extension, which corpus.json does not keep');
      }
      blob(path, entry, '$dir/$relative');
    }
    if (files.length != source['files']) {
      problem('sources.json', '"${source['name']}" has ${files.length} files, sources.json says ${source['files']}');
    }
    if (bytes != source['bytes']) {
      problem('sources.json', '"${source['name']}" has $bytes bytes, sources.json says ${source['bytes']}');
    }
    for (final relative in under('$dir/')) {
      if (!sourceExtras.contains(relative) && !listed.contains(relative)) {
        problem('$dir/$relative', 'in the tree but not in manifest.json');
      }
    }
  }

  // ----- a snippet collection -----

  void snippetCollection() {
    const path = 'manifest.json';
    final json = readJson(path);
    if (json is! Map<String, dynamic>) {
      if (json != null) problem(path, 'expected an object');
      return;
    }
    string(path, json, 'description');
    final sources = json['sources'];
    final sourceKeys = <String>{};
    if (sources is! Map<String, dynamic>) {
      problem(path, '"sources" is not an object');
    } else {
      for (final MapEntry(:key, :value) in sources.entries) {
        sourceKeys.add(key);
        if (value is! Map<String, dynamic>) {
          problem(path, 'source "$key" is not an object');
          continue;
        }
        string(path, value, 'name');
        url(path, value, 'pageUrl');
        string(path, value, 'basis');
      }
    }
    if (!json.containsKey('snippets')) problem(path, 'missing "snippets"');
    final snippets = jsonList(path, json['snippets']);
    final listed = <String>{};
    if (snippets != null) {
      String? previous;
      for (final entry in snippets) {
        final name = string(path, entry, 'file');
        integer(path, entry, 'bytes');
        url(path, entry, 'pageUrl');
        url(path, entry, 'imageUrl');
        for (final optional in ['author', 'uploader', 'license']) {
          string(path, entry, optional, required: false);
        }
        url(path, entry, 'authorLink', required: false);
        if (name == null) continue;
        if (!listed.add(name)) problem(path, '"$name" is listed twice');
        if (previous != null && previous.compareTo(name) > 0) problem(path, '"$name" is out of order');
        previous = name;
        if (!name.toLowerCase().endsWith('.png')) problem(path, '"$name" is not a PNG');
        final slash = name.indexOf('/');
        if (slash < 0 || !sourceKeys.contains(name.substring(0, slash))) {
          problem(path, '"$name" is not under a directory named in "sources"');
        }
        blob(path, entry, name);
      }
    }
    for (final name in tree.keys) {
      if (name.toLowerCase().endsWith('.png') && !listed.contains(name)) problem(name, 'not listed in manifest.json');
    }
    _heldJson();
    _licensesMd(sourceKeys);
    if (!tree.containsKey('INTERESTING.txt')) problem('INTERESTING.txt', 'missing from the tree');
    notes.add('${listed.length} snippets checked');
  }

  void _heldJson() {
    if (!tree.containsKey('held.json')) return;
    final list = jsonList('held.json', readJson('held.json'));
    if (list == null) return;
    for (final entry in list) {
      string('held.json', entry, 'source');
      if (entry.containsKey('count')) {
        integer('held.json', entry, 'count');
        string('held.json', entry, 'reason');
      } else {
        string('held.json', entry, 'reason', required: false);
        url('held.json', entry, 'pageUrl');
        url('held.json', entry, 'imageUrl');
      }
    }
  }

  void _licensesMd(Set<String> sourceKeys) {
    const path = 'LICENSES.md';
    if (!tree.containsKey(path)) {
      problem(path, 'missing from the tree');
      return;
    }
    if (!file(path).existsSync()) {
      problem(path, 'not checked out');
      return;
    }
    final text = file(path).readAsStringSync();
    for (final key in sourceKeys) {
      if (!text.contains('`$key`')) problem(path, 'does not name the source `$key`');
    }
  }
}
