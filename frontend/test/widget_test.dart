import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:frontend/main.dart';
import 'package:frontend/analysis.dart';
import 'package:frontend/services/classifier.dart';
import 'package:frontend/services/history_store.dart';
import 'package:frontend/services/photo_input.dart';

class FakeClassifier implements Classifier {
  @override
  Future<String> load() async => 'test-model';
  @override
  Future<Analysis> predict(Uint8List bytes) async => Analysis(
    id: '1',
    createdAt: DateTime.utc(2026),
    scores: [.1, .8, .1],
    modelVersion: 'test-model',
    elapsedMs: 20,
  );
}

class MemoryHistory implements HistoryStore {
  final rows = <Analysis>[];
  @override
  Future<List<Analysis>> list({int limit = 20, Analysis? after, String? category}) async {
    final start = after == null ? 0 : rows.indexWhere((r) => r.id == after.id) + 1;
    return rows.skip(start).where((r) => category == null || r.categoryKey == category)
        .take(limit).toList();
  }

  SavePreferences value = const SavePreferences();
  Uint8List? lastBytes;

  @override
  Future<int> count() async => rows.length;
  @override
  Future<SavePreferences> preferences() async => value;
  @override
  Future<void> setPreferences(SavePreferences preferences) async {
    value = preferences;
  }
  @override
  Future<void> save(Analysis a, Uint8List? bytes) async {
    lastBytes = bytes;
    rows.add(a);
  }

  @override
  Future<void> delete(Analysis a) async {
    rows.remove(a);
  }

  @override
  Future<void> clear() async {
    rows.clear();
  }

  @override
  Future<void> close() async {}
}

class FakePhotoInput extends PhotoInput {
  @override
  Future<XFile?> pick(ImageSource source) async =>
      XFile.fromData(Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64))));
  @override
  Future<Uint8List> read(XFile file) => file.readAsBytes();
  @override
  Future<XFile?> recover() async => null;
}

void main() {
  testWidgets('Dashboard uses real empty history and navigates to analysis', (
    tester,
  ) async {
    await tester.pumpWidget(
      TomatoLensApp(classifier: FakeClassifier(), history: MemoryHistory()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Una mirada a tus hojas'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    await tester.tap(find.text('Comenzar análisis'));
    await tester.pumpAndSettle();
    expect(find.text('Analizar una hoja'), findsOneWidget);
    expect(find.text('Galería'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.history_rounded).last);
    await tester.pumpAndSettle();
    expect(find.text('Aún no hay análisis guardados'), findsOneWidget);
  });
  testWidgets('Guide explains limits without invoking native plugins', (
    tester,
  ) async {
    await tester.pumpWidget(
      TomatoLensApp(classifier: FakeClassifier(), history: MemoryHistory()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guía'));
    await tester.pumpAndSettle();
    expect(find.text('Conoce el alcance'), findsOneWidget);
  });

  testWidgets('Analysis honors opt-in automatic saving without a photo', (tester) async {
    final history = MemoryHistory()
      ..value = const SavePreferences(keepPhoto: false, autoSave: true);
    await tester.pumpWidget(TomatoLensApp(
      classifier: FakeClassifier(),
      history: history,
      photoInput: FakePhotoInput(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comenzar análisis'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Galería'));
    // The progress indicator keeps ticking while the preview awaits input.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final analyzeButton = find.widgetWithText(FilledButton, 'Analizar hoja');
    expect(analyzeButton, findsOneWidget);
    await tester.tap(analyzeButton);
    await tester.pumpAndSettle();
    expect(history.rows.single.categoryKey, 'healthy');
    expect(history.lastBytes, isNull);
    await tester.tap(find.text('Historial'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Hoja sana'), findsOneWidget);
  });
}
