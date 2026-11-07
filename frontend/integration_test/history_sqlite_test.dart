import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/analysis.dart';
import 'package:frontend/services/history_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Migrates v1 data; saves, pages, reopens and deletes locally', (_) async {
    final dir = await Directory.systemTemp.createTemp('tomatolens-history-test');
    final store = SqliteHistoryStore(directory: () async => dir);
    try {
      final old = await openDatabase(
        p.join(dir.path, 'tomatolens.db'),
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE analyses (id TEXT PRIMARY KEY, created_at TEXT NOT NULL, '
          'scores TEXT NOT NULL, model_version TEXT NOT NULL, '
          'elapsed_ms INTEGER NOT NULL, image_name TEXT NOT NULL)',
        ),
      );
      final photos = await Directory(p.join(dir.path, 'analyses')).create();
      final existingPhoto = await File(p.join(photos.path, 'old.img'))
          .writeAsBytes([1, 2, 3]);
      try {
        await old.insert('analyses', {
          'id': 'old',
          'created_at': '2026-01-01T00:00:00.000Z',
          'scores': '[0.1,0.8,0.1]',
          'model_version': 'legacy-v1',
          'elapsed_ms': 12,
          'image_name': 'old.img',
        });
      } finally {
        await old.close();
      }

      expect((await store.list()).single.imagePath, existingPhoto.path);
      expect(await existingPhoto.exists(), isTrue);
      await store.setPreferences(const SavePreferences(keepPhoto: false, autoSave: true));
      final result = Analysis(
        id: 'new',
        createdAt: DateTime.utc(2026, 1, 2),
        scores: const [.2, .6, .2],
        modelVersion: 'test',
        elapsedMs: 10,
        inconclusive: true,
      );
      await store.save(result, null);
      await store.save(result, Uint8List.fromList([8, 9]));
      await store.close();
      expect(await store.count(), 2);
      expect((await store.preferences()).keepPhoto, isFalse);
      expect((await store.preferences()).autoSave, isTrue);
      final first = (await store.list(limit: 1)).single;
      expect(first.imagePath, isNull);
      expect(first.inconclusive, isTrue);
      expect((await store.list(limit: 1, after: first)).single.id, 'old');
      expect((await store.list(category: 'healthy')).single.id, 'old');
      expect((await store.list(category: inconclusiveKey)).single.id, 'new');
      await store.delete((await store.list(category: 'healthy')).single);
      expect(await existingPhoto.exists(), isFalse);
      await store.clear();
      expect(await store.count(), 0);
      expect(await photos.list().isEmpty, isTrue);
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}
