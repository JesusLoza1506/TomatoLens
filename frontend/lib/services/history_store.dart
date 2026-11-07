import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../analysis.dart';

class SavePreferences {
  const SavePreferences({this.keepPhoto = true, this.autoSave = false});

  final bool keepPhoto;
  final bool autoSave;
}

abstract class HistoryStore {
  Future<List<Analysis>> list({int limit = 20, Analysis? after, String? category});
  Future<int> count();
  Future<SavePreferences> preferences();
  Future<void> setPreferences(SavePreferences value);
  Future<void> save(Analysis analysis, Uint8List? bytes);
  Future<void> delete(Analysis analysis);
  Future<void> clear();
  Future<void> close();
}

class SqliteHistoryStore implements HistoryStore {
  SqliteHistoryStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  Future<Database>? _database;
  late Directory _images;

  Future<Database> _open() => _database ??= _openDatabase();

  Future<Database> _openDatabase() async {
    try {
      final base = await _directory();
      _images = await Directory(
        p.join(base.path, 'analyses'),
      ).create(recursive: true);
      return await openDatabase(
        p.join(base.path, 'tomatolens.db'),
        version: 2,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion != 1) {
            throw StateError('Versión del historial no compatible.');
          }
          await db.execute('ALTER TABLE analyses RENAME TO analyses_v1');
          await _createSchema(db);
          var offset = 0;
          while (true) {
            final rows = await db.query(
              'analyses_v1',
              orderBy: 'id',
              limit: 100,
              offset: offset,
            );
            if (rows.isEmpty) break;
            final batch = db.batch();
            for (final row in rows) {
              batch.insert('analyses', {
                ...row,
                'category_key': _decode(row).categoryKey,
                'created_at': _encodeDate(DateTime.parse(row['created_at'] as String)),
              });
            }
            await batch.commit(noResult: true);
            offset += rows.length;
          }
          await db.execute('DROP TABLE analyses_v1');
        },
      );
    } catch (_) {
      _database = null;
      rethrow;
    }
  }

  Future<void> _createSchema(Database db) async {
    await db.execute(
      'CREATE TABLE analyses ('
      'id TEXT PRIMARY KEY, created_at TEXT NOT NULL, scores TEXT NOT NULL, '
      'model_version TEXT NOT NULL, elapsed_ms INTEGER NOT NULL, '
      'image_name TEXT, category_key TEXT NOT NULL)',
    );
    await db.execute('CREATE INDEX analyses_date ON analyses(created_at DESC, id DESC)');
    await db.execute(
      'CREATE INDEX analyses_category_date '
      'ON analyses(category_key, created_at DESC, id DESC)',
    );
    await db.execute(
      'CREATE TABLE preferences (id INTEGER PRIMARY KEY, '
      'keep_photo INTEGER NOT NULL, auto_save INTEGER NOT NULL)',
    );
  }

  String _encodeDate(DateTime date) {
    final iso = date.toUtc().toIso8601String();
    return date.microsecond == 0 ? '${iso.substring(0, iso.length - 1)}000Z' : iso;
  }

  Analysis _decode(Map<String, Object?> r) {
    final imageName = r['image_name'] as String?;
    return Analysis(
      id: r['id'] as String,
      createdAt: DateTime.parse(r['created_at'] as String),
      scores: (jsonDecode(r['scores'] as String) as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      modelVersion: r['model_version'] as String,
      elapsedMs: r['elapsed_ms'] as int,
      imagePath: imageName == null ? null : p.join(_images.path, imageName),
      inconclusive: r['category_key'] == inconclusiveKey,
    );
  }

  @override
  Future<List<Analysis>> list({
    int limit = 20,
    Analysis? after,
    String? category,
  }) async {
    final db = await _open();
    final conditions = <String>[];
    final args = <Object>[];
    if (category != null) {
      conditions.add('category_key = ?');
      args.add(category);
    }
    if (after != null) {
      final date = _encodeDate(after.createdAt);
      conditions.add('(created_at < ? OR (created_at = ? AND id < ?))');
      args.addAll([date, date, after.id]);
    }
    final rows = await db.query(
      'analyses',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_decode).toList();
  }

  @override
  Future<int> count() async =>
      Sqflite.firstIntValue(await (await _open()).rawQuery('SELECT COUNT(*) FROM analyses')) ?? 0;

  @override
  Future<SavePreferences> preferences() async {
    final rows = await (await _open()).query('preferences', where: 'id = 1');
    if (rows.isEmpty) return const SavePreferences();
    return SavePreferences(
      keepPhoto: rows.single['keep_photo'] == 1,
      autoSave: rows.single['auto_save'] == 1,
    );
  }

  @override
  Future<void> setPreferences(SavePreferences value) async {
    await (await _open()).insert('preferences', {
      'id': 1,
      'keep_photo': value.keepPhoto ? 1 : 0,
      'auto_save': value.autoSave ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> save(Analysis analysis, Uint8List? bytes) async {
    final db = await _open();
    final name = '${analysis.id}.img';
    final file = File(p.join(_images.path, name));
    var wroteFile = false;
    await db.transaction((tx) async {
      if ((await tx.query('analyses', where: 'id = ?', whereArgs: [analysis.id])).isNotEmpty) {
        return;
      }
      try {
        if (bytes != null) {
          wroteFile = true;
          await file.writeAsBytes(bytes, flush: true);
        }
        await tx.insert('analyses', {
          'id': analysis.id,
          'created_at': _encodeDate(analysis.createdAt),
          'scores': jsonEncode(analysis.scores),
          'model_version': analysis.modelVersion,
          'elapsed_ms': analysis.elapsedMs,
          'image_name': bytes == null ? null : name,
          'category_key': analysis.categoryKey,
        });
      } catch (_) {
        if (wroteFile && await file.exists()) await file.delete();
        rethrow;
      }
    });
  }

  @override
  Future<void> delete(Analysis analysis) async {
    final db = await _open();
    await db.transaction((tx) async {
      final rows = await tx.query(
        'analyses',
        columns: ['image_name'],
        where: 'id = ?',
        whereArgs: [analysis.id],
      );
      if (rows.isEmpty) return;
      final name = rows.single['image_name'] as String?;
      if (name != null && p.basename(name) == name) {
        final file = File(p.join(_images.path, name));
        if (await file.exists()) await file.delete();
      }
      await tx.delete('analyses', where: 'id = ?', whereArgs: [analysis.id]);
    });
  }

  @override
  Future<void> clear() async {
    while (true) {
      final rows = await list();
      if (rows.isEmpty) return;
      for (final row in rows) {
        await delete(row);
      }
    }
  }

  @override
  Future<void> close() async {
    final pending = _database;
    _database = null;
    if (pending != null) await (await pending).close();
  }
}
