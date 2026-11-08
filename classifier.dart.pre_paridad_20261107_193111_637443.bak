import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import '../analysis.dart';

abstract class Classifier {
  Future<String> load();
  Future<Analysis> predict(Uint8List bytes);
}

class LocalClassifier implements Classifier {
  Uint8List? _model;
  String _version = '';
  double? _minScore;
  @override
  Future<String> load() async {
    final model = await rootBundle.load('assets/models/tomatolens_v1.tflite');
    final bytes = model.buffer.asUint8List(
      model.offsetInBytes,
      model.lengthInBytes,
    );
    final labels = jsonDecode(
      await rootBundle.loadString('assets/models/labels.json'),
    );
    final meta =
        jsonDecode(
              await rootBundle.loadString('assets/models/model_metadata.json'),
            )
            as Map<String, dynamic>;
    if (!listEquals(List<String>.from(labels as List), classKeys) ||
        !listEquals(List<String>.from(meta['labels'] as List), classKeys) ||
        meta['input_dtype'] != 'float32' ||
        !listEquals(List<int>.from(meta['input_shape'] as List), [
          1,
          224,
          224,
          3,
        ]) ||
        !listEquals(List<int>.from(meta['input_range'] as List), [0, 255]) ||
        meta['resize'] != 'half_pixel_bilinear_v1' ||
        meta['color_order'] != 'RGB') {
      throw StateError(
        'El modelo y sus etiquetas no son compatibles con esta versión.',
      );
    }
    if (sha256.convert(bytes).toString() != meta['sha256']) {
      throw StateError(
        'El modelo no coincide con sus metadatos. Repite la exportación.',
      );
    }
    final policy = meta['decision_policy'];
    double? threshold;
    if (policy != null) {
      if (meta['independently_evaluated'] != true ||
          policy is! Map<String, dynamic> ||
          policy['min_score'] is! num) {
        throw StateError('La política de decisión no es válida.');
      }
      threshold = (policy['min_score'] as num).toDouble();
      if (!threshold.isFinite || threshold < 0 || threshold > 1) {
        throw StateError('El umbral de decisión está fuera de rango.');
      }
    }
    _minScore = threshold;
    _model = bytes;
    _version = meta['model_version'] as String;
    return _version;
  }

  @override
  Future<Analysis> predict(Uint8List bytes) async {
    final model = _model;
    if (model == null) throw StateError('El modelo todavía no está listo.');
    final watch = Stopwatch()..start();
    final scores = await compute(runInference, {
      'model': model,
      'image': bytes,
    });
    final now = DateTime.now().toUtc();
    return Analysis(
      id: now.microsecondsSinceEpoch.toString(),
      createdAt: now,
      scores: scores,
      modelVersion: _version,
      elapsedMs: watch.elapsedMilliseconds,
      inconclusive: _minScore != null &&
          scores.reduce((a, b) => a > b ? a : b) < _minScore!,
    );
  }
}

// Exact float32 contract shared with ml/src/common.py. No division by 255 here.
Float32List preprocessImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('No se pudo leer la imagen. Usa JPG o PNG.');
  }
  final image = img.bakeOrientation(decoded).convert(numChannels: 3);
  final tensor = Float32List(224 * 224 * 3);
  var index = 0;
  for (var y = 0; y < 224; y++) {
    final fy = ((y + .5) * image.height / 224 - .5).clamp(
      0.0,
      image.height - 1.0,
    );
    final y0 = fy.floor();
    final y1 = (y0 + 1).clamp(0, image.height - 1).toInt();
    final wy = fy - y0;
    for (var x = 0; x < 224; x++) {
      final fx = ((x + .5) * image.width / 224 - .5).clamp(
        0.0,
        image.width - 1.0,
      );
      final x0 = fx.floor();
      final x1 = (x0 + 1).clamp(0, image.width - 1).toInt();
      final wx = fx - x0;
      final a = image.getPixel(x0, y0), b = image.getPixel(x1, y0);
      final c = image.getPixel(x0, y1), d = image.getPixel(x1, y1);
      final channels = [
        [a.r.toDouble(), b.r.toDouble(), c.r.toDouble(), d.r.toDouble()],
        [a.g.toDouble(), b.g.toDouble(), c.g.toDouble(), d.g.toDouble()],
        [a.b.toDouble(), b.b.toDouble(), c.b.toDouble(), d.b.toDouble()],
      ];
      for (final ch in channels) {
        tensor[index++] =
            ((1 - wx) * ch[0] + wx * ch[1]) * (1 - wy) +
            ((1 - wx) * ch[2] + wx * ch[3]) * wy;
      }
    }
  }
  return tensor;
}

List<double> runInference(Map<String, Uint8List> args) {
  final interpreter = Interpreter.fromBuffer(
    args['model']!,
    options: InterpreterOptions()..threads = 2,
  );
  try {
    final input = interpreter.getInputTensor(0);
    final output = interpreter.getOutputTensor(0);
    if (!listEquals(input.shape, [1, 224, 224, 3]) ||
        input.type != TensorType.float32 ||
        !listEquals(output.shape, [1, 3]) ||
        output.type != TensorType.float32) {
      throw StateError('Dimensiones o tipo del modelo no compatibles.');
    }
    final tensor = preprocessImage(args['image']!);
    final result = [List<double>.filled(3, 0)];
    interpreter.run(tensor.buffer, result);
    final scores = result.first;
    if (scores.any((s) => !s.isFinite || s < 0 || s > 1) ||
        (scores.reduce((a, b) => a + b) - 1).abs() > .01) {
      throw StateError('El modelo devolvió puntuaciones inválidas.');
    }
    return scores;
  } finally {
    interpreter.close();
  }
}
