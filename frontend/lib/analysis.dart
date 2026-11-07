const classKeys = ['early_blight', 'healthy', 'late_blight'];
const inconclusiveKey = 'inconclusive';
const classNames = ['Tizón temprano', 'Hoja sana', 'Tizón tardío'];

class Analysis {
  const Analysis({
    required this.id,
    required this.createdAt,
    required this.scores,
    required this.modelVersion,
    required this.elapsedMs,
    this.imagePath,
    this.inconclusive = false,
  });
  final String id;
  final DateTime createdAt;
  final List<double> scores;
  final String modelVersion;
  final int elapsedMs;
  final String? imagePath;
  final bool inconclusive;
  int get winner {
    var best = 0;
    for (var i = 1; i < scores.length; i++) {
      if (scores[i] > scores[best]) best = i;
    }
    return best;
  }

  String get categoryKey => inconclusive ? inconclusiveKey : classKeys[winner];
  String get title => inconclusive ? 'No concluyente' : classNames[winner];
  double get score => scores[winner];
  Analysis withImage(String? path) => Analysis(
    id: id,
    createdAt: createdAt,
    scores: scores,
    modelVersion: modelVersion,
    elapsedMs: elapsedMs,
    imagePath: path,
    inconclusive: inconclusive,
  );
}
