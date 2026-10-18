import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:sqlite3/sqlite3.dart';

/// Run: `dart run index <repository> <out.sqlite>` (from `tool/index`).
///
/// Builds the SQLite index of this corpus repository: one row per VI, control, snippet,
/// library, class and project file under it, with the file's name and saving version, the
/// `primResID`s and block-diagram and front-panel class codes its heaps hold (each with how
/// many objects carry it), its sub-VI and owning-library names, or a library file's members,
/// read with the labwright parser the pubspec pins. Schema 1:
///
/// - `meta(key, value)`: `schema`, `repository`, `commit`, `labwright`, `built`, `files`.
/// - `file(id, path, source, bytes, type, name, version, error)`: one row per file, `path`
///   relative to the repository root, `source` the vendored source's directory name or null,
///   `type` the extension, `error` why the file did not parse.
/// - `prim(file, id, n)`, `bd_object(file, code, n)`, `fp_object(file, code, n)`: ids and
///   object counts per file; `prim_name(id, name)`, `bd_class(code, name)`, `fp_class(code,
///   name)`: the names the parser's catalogues give the ids they know; the views `prims`,
///   `bd_objects` and `fp_objects` join them.
/// - `sub_vi(file, name)`, `library(file, name)`, `member(file, name)`.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run index <repository> <out.sqlite>');
    exitCode = 2;
    return;
  }
  final root = Directory(args[0]).absolute;
  final out = File(args[1]).absolute;
  final watch = Stopwatch()..start();
  final records = await _records(root);
  final labwright = _labwrightRef();
  _write(
    out,
    records,
    repository: root.uri.pathSegments.where((s) => s.isNotEmpty).last,
    commit: await _head(root),
    labwright: labwright,
  );
  final errors = records.where((r) => r.error != null).length;
  stdout.writeln(
    '${records.length} files indexed in ${watch.elapsed.inSeconds}s'
    '${errors == 0 ? '' : ', $errors did not parse'}: '
    '${out.path} (${(out.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB)',
  );
}

const int schema = 1;

const Map<String, String> extensions = {
  'vi': 'VI',
  'ctl': 'Control',
  'vim': 'Malleable VI',
  'vit': 'VI template',
  'ctt': 'Control template',
  'llb': 'VI library archive',
  'lvlib': 'Library',
  'lvclass': 'Class',
  'xctl': 'XControl',
  'lvproj': 'Project',
  'png': 'VI snippet',
};

const Set<String> xmlExtensions = {'lvlib', 'lvclass', 'xctl', 'lvproj'};

String? _extension(String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot <= slash) return null;
  final extension = path.substring(dot + 1).toLowerCase();
  return extensions.containsKey(extension) ? extension : null;
}

class Record {
  const Record({
    required this.path,
    required this.bytes,
    required this.type,
    this.name,
    this.version,
    this.prims = const {},
    this.bdClasses = const {},
    this.fpClasses = const {},
    this.subVis = const [],
    this.libraries = const [],
    this.members = const [],
    this.error,
  });

  final String path;
  final int bytes;
  final String type;
  final String? name;
  final String? version;
  final Map<int, int> prims;
  final Map<int, int> bdClasses;
  final Map<int, int> fpClasses;
  final List<String> subVis;
  final List<String> libraries;
  final List<String> members;
  final String? error;
}

/// The record for the file at [path] holding [bytes]: null for a file the index does not
/// record, or a PNG that carries no VI.
Record? recordOf(String path, Uint8List bytes) {
  final type = _extension(path);
  if (type == null) return null;
  final fileName = path.substring(path.lastIndexOf('/') + 1);
  if (xmlExtensions.contains(type)) {
    try {
      final library = LvLibraryFile.parse(
        utf8.decode(bytes, allowMalformed: true),
        fileName: fileName,
      );
      return Record(
        path: path,
        bytes: bytes.length,
        type: type,
        name: fileName,
        members: _distinct([
          for (final item in library.items)
            if (item.url != null) item.name,
        ]),
      );
    } catch (e) {
      return Record(
        path: path,
        bytes: bytes.length,
        type: type,
        name: fileName,
        error: _oneLine(e),
      );
    }
  }
  var vi = bytes;
  if (type == 'png') {
    final embedded = extractSnippetVi(bytes);
    if (embedded == null) return null;
    vi = embedded;
  }
  try {
    final summary = parseVi(vi);
    final sections = readViSections(vi);
    final version = versionFromSections(sections);
    final decoded = [for (final section in sections) inflateSection(section)];
    final model = buildViModelFromDecoded(
      decoded,
      subViNames: subViNamesOf(sections, vi),
    );
    final prims = <int, int>{};
    final bd = <int, int>{};
    for (final diagram in model.blockDiagrams) {
      for (final object in diagram.objects) {
        bd.update(object.kind, (n) => n + 1, ifAbsent: () => 1);
        final id = object.primitive?.primResId;
        if (id != null) prims.update(id, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final fp = <int, int>{};
    for (final panel in model.frontPanels) {
      for (final object in panel.objects) {
        fp.update(object.kind, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return Record(
      path: path,
      bytes: bytes.length,
      type: type,
      name: summary.name ?? version.title,
      version: version.version,
      prims: prims,
      bdClasses: bd,
      fpClasses: fp,
      subVis: _distinct(model.subViNames),
      libraries: _distinct(readOwningLibraryNames(vi)),
    );
  } catch (e) {
    return Record(
      path: path,
      bytes: bytes.length,
      type: type,
      error: _oneLine(e),
    );
  }
}

List<String> _distinct(Iterable<String> names) {
  final seen = <String>{};
  return [
    for (final name in names)
      if (seen.add(name)) name,
  ];
}

String _oneLine(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

/// The files under [root] the index records, by path relative to [root] with `/` separators,
/// sorted; a nested repository (a directory holding `.git`) is not part of the corpus.
List<String> _files(Directory root) {
  final prefix = root.path.length + 1;
  final out = <String>[];
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    if (dir.path != root.path &&
        FileSystemEntity.typeSync('${dir.path}/.git') !=
            FileSystemEntityType.notFound) {
      continue;
    }
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        if (entity.uri.pathSegments.where((s) => s.isNotEmpty).last != '.git')
          pending.add(entity);
      } else if (entity is File) {
        final relative = entity.path.substring(prefix).replaceAll(r'\', '/');
        if (_extension(relative) != null) out.add(relative);
      }
    }
  }
  return out..sort();
}

Future<List<Record>> _records(Directory root) async {
  final paths = _files(root);
  final n = (Platform.numberOfProcessors - 1).clamp(
    1,
    paths.isEmpty ? 1 : paths.length.clamp(1, 16),
  );
  final chunks = List.generate(n, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % n].add(paths[i]);
  }
  final rootPath = root.path;
  final parts = await Future.wait([
    for (final chunk in chunks)
      if (chunk.isNotEmpty)
        Isolate.run(
          () => [
            for (final path in chunk)
              if (recordOf(path, File('$rootPath/$path').readAsBytesSync())
                  case final record?)
                record,
          ],
        ),
  ]);
  return [for (final part in parts) ...part]
    ..sort((a, b) => a.path.compareTo(b.path));
}

void _write(
  File out,
  List<Record> records, {
  required String repository,
  required String commit,
  required String labwright,
}) {
  if (out.existsSync()) out.deleteSync();
  final db = sqlite3.open(out.path);
  try {
    db.execute('''
      pragma journal_mode = off;
      pragma synchronous = off;
      create table meta(key text primary key, value text not null);
      create table file(
        id integer primary key,
        path text not null unique,
        source text,
        bytes integer not null,
        type text not null,
        name text,
        version text,
        error text
      );
      create table prim(file integer not null references file(id), id integer not null, n integer not null);
      create table bd_object(file integer not null references file(id), code integer not null, n integer not null);
      create table fp_object(file integer not null references file(id), code integer not null, n integer not null);
      create table prim_name(id integer primary key, name text not null);
      create table bd_class(code integer primary key, name text not null);
      create table fp_class(code integer primary key, name text not null);
      create view prims as
        select p.file, p.id, n.name, p.n from prim p left join prim_name n on n.id = p.id;
      create view bd_objects as
        select o.file, o.code, c.name, o.n from bd_object o left join bd_class c on c.code = o.code;
      create view fp_objects as
        select o.file, o.code, c.name, o.n from fp_object o left join fp_class c on c.code = o.code;
      create table sub_vi(file integer not null references file(id), name text not null);
      create table library(file integer not null references file(id), name text not null);
      create table member(file integer not null references file(id), name text not null);
    ''');
    final insertMeta = db.prepare('insert into meta values (?, ?)');
    for (final MapEntry(:key, :value) in {
      'schema': '$schema',
      'repository': repository,
      'commit': commit,
      'labwright': labwright,
      'built': DateTime.now().toUtc().toIso8601String(),
      'files': '${records.length}',
    }.entries) {
      insertMeta.execute([key, value]);
    }
    final insertFile = db.prepare(
      'insert into file(id, path, source, bytes, type, name, version, error) values (?, ?, ?, ?, ?, ?, ?, ?)',
    );
    final insertPrim = db.prepare('insert into prim values (?, ?, ?)');
    final insertBd = db.prepare('insert into bd_object values (?, ?, ?)');
    final insertFp = db.prepare('insert into fp_object values (?, ?, ?)');
    final insertSubVi = db.prepare('insert into sub_vi values (?, ?)');
    final insertLibrary = db.prepare('insert into library values (?, ?)');
    final insertMember = db.prepare('insert into member values (?, ?)');
    final prims = <int>{};
    final bdClasses = <int>{};
    final fpClasses = <int>{};
    db.execute('begin');
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final id = i + 1;
      insertFile.execute([
        id,
        record.path,
        _sourceOf(record.path),
        record.bytes,
        record.type,
        record.name,
        record.version,
        record.error,
      ]);
      for (final MapEntry(key: prim, value: n) in record.prims.entries) {
        insertPrim.execute([id, prim, n]);
        prims.add(prim);
      }
      for (final MapEntry(key: code, value: n) in record.bdClasses.entries) {
        insertBd.execute([id, code, n]);
        bdClasses.add(code);
      }
      for (final MapEntry(key: code, value: n) in record.fpClasses.entries) {
        insertFp.execute([id, code, n]);
        fpClasses.add(code);
      }
      for (final name in record.subVis) {
        insertSubVi.execute([id, name]);
      }
      for (final name in record.libraries) {
        insertLibrary.execute([id, name]);
      }
      for (final name in record.members) {
        insertMember.execute([id, name]);
      }
    }
    final insertPrimName = db.prepare('insert into prim_name values (?, ?)');
    for (final prim in prims) {
      if (PrimOp.fromId(prim) case final op?)
        insertPrimName.execute([prim, op.opName]);
    }
    final insertBdClass = db.prepare('insert into bd_class values (?, ?)');
    for (final code in bdClasses) {
      if (BdObjectClass.fromCode(code) case final cls
          when cls != BdObjectClass.unknown) {
        insertBdClass.execute([code, cls.label]);
      }
    }
    final insertFpClass = db.prepare('insert into fp_class values (?, ?)');
    for (final code in fpClasses) {
      if (FpObjectClass.fromCode(code) case final cls
          when cls != FpObjectClass.unknown) {
        insertFpClass.execute([code, cls.label]);
      }
    }
    db.execute('commit');
    for (final statement in [
      insertMeta,
      insertFile,
      insertPrim,
      insertBd,
      insertFp,
      insertSubVi,
      insertLibrary,
      insertMember,
      insertPrimName,
      insertBdClass,
      insertFpClass,
    ]) {
      statement.close();
    }
    db.execute('''
      create index file_source on file(source);
      create index file_type on file(type);
      create index file_name on file(name collate nocase);
      create index prim_id on prim(id);
      create index bd_object_code on bd_object(code);
      create index fp_object_code on fp_object(code);
      create index prim_name_name on prim_name(name collate nocase);
      create index bd_class_name on bd_class(name collate nocase);
      create index fp_class_name on fp_class(name collate nocase);
      create index sub_vi_name on sub_vi(name collate nocase);
      create index library_name on library(name collate nocase);
      create index member_name on member(name collate nocase);
      vacuum;
    ''');
  } finally {
    db.close();
  }
}

/// The vendored source a path under `sources/` belongs to, or null for a file outside one.
String? _sourceOf(String path) {
  const prefix = 'sources/';
  if (!path.startsWith(prefix)) return null;
  final slash = path.indexOf('/', prefix.length);
  return slash < 0 ? null : path.substring(prefix.length, slash);
}

Future<String> _head(Directory dir) async {
  final result = await Process.run('git', [
    '-C',
    dir.path,
    'rev-parse',
    'HEAD',
  ]);
  return result.exitCode == 0 ? (result.stdout as String).trim() : 'unknown';
}

/// The labwright commit the pubspec pins the parser at.
String _labwrightRef() {
  final pubspec = File.fromUri(Platform.script.resolve('../pubspec.yaml'));
  if (!pubspec.existsSync()) return 'unknown';
  final match = RegExp(
    r'^\s*ref:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  return match?.group(1) ?? 'unknown';
}
