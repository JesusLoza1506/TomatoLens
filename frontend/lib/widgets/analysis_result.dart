import 'package:flutter/material.dart';

import '../analysis.dart';

class AnalysisResult extends StatelessWidget {
  const AnalysisResult({super.key, required this.result, required this.formatDate});

  final Analysis result;
  final String Function(DateTime) formatDate;

  @override
  Widget build(BuildContext context) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          result.inconclusive ? 'EVIDENCIA INSUFICIENTE' : 'MAYOR PUNTUACIÓN',
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.4,
            color: Color(0xFF647267),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          result.inconclusive ? 'Resultado no concluyente' : result.title,
          style: const TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w800,
            color: Color(0xFF20382D),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          result.inconclusive
              ? 'La puntuación no alcanza el umbral del modelo. Prueba con otra foto bien iluminada.'
              : '${(result.score * 100).toStringAsFixed(1)} % · salida del modelo',
          style: const TextStyle(color: Color(0xFF174F3B), fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 22),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: Text(classNames[i])),
                    Text('${(result.scores[i] * 100).toStringAsFixed(1)} %'),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 7,
                    value: result.scores[i].clamp(0, 1),
                    color: i == result.winner
                        ? const Color(0xFF174F3B)
                        : const Color(0xFFACC3A2),
                    backgroundColor: const Color(0xFFEEF1E8),
                  ),
                ),
              ],
            ),
          ),
        Text(
          '${formatDate(result.createdAt)} · ${(result.elapsedMs / 1000).toStringAsFixed(2)} s\nModelo ${result.modelVersion}',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF647267),
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Apoyo visual, no diagnóstico. La puntuación no está calibrada como probabilidad de enfermedad.',
          style: TextStyle(fontSize: 12, height: 1.4),
        ),
      ],
    );
}
