# Revisión técnica y cambios realizados

## Hallazgos comprobados

1. Doble normalización: train.py incorpora Rescaling(1/255), y main.dart enviaba píxeles ya divididos por 255. La entrada efectiva era RGB/65025.
2. MobileNetV2 ImageNet espera el preprocesamiento [-1,1]. El modelo original se entrenó con [0,1]; se conserva como legado y el pipeline nuevo corrige el entrenamiento.
3. Validación/prueba se separaban con take/skip sobre lotes barajados. No eran particiones fijas independientes; tampoco se evaluaba test.
4. shuffle(1000) después de batch y cache de float32 podían consumir mucha RAM.
5. No se guardaban particiones, historial, metadatos ni mejor checkpoint.
6. La prueba widget usaba MyApp y el contador de ejemplo, pero esa clase ya no existía.
7. ML CI pedía ml/tests, carpeta inexistente en el ZIP.
8. Inferencia síncrona en la interfaz, sin control de doble pulsación, sin cierre de intérprete y con pocos controles de error.
9. Artefacto Keras 2.15 creado en Windows contiene rutas HDF5 con barras invertidas: se añadió carga compatible POSIX mediante una copia temporal; los pesos originales no se cambian.

## Prueba con las nueve imágenes recibidas

Son ejemplos del mismo origen que el entrenamiento y podrían haber sido usados para entrenar. Esta comparación NO estima exactitud independiente.

| Categoría de la carpeta | Muestras | Coincidencias entrada original Flutter (0..1) | Coincidencias entrada corregida (0..255) |
|---|---:|---:|---:|
| early_blight | 3 | 0 | 3 |
| healthy | 3 | 0 | 3 |
| late_blight | 3 | 3 | 3 |

Diferencia absoluta máxima Keras/TFLite ORIGINAL: 0.000002265.

Se volvió a exportar el modelo recibido sin reentrenar ni alterar sus pesos. Paridad de la NUEVA exportación comprobada en nueve imágenes: diferencia máxima 0.000000775; mismo argmax en todas. Ver `ml/artifacts/export_parity.json`.

Auditoría de las nueve muestras: legibles, sin duplicados exactos ni pares dHash <=2. No se auditó el conjunto completo de 4500 imágenes porque no está adjunto.

## Cambios de app

- Dashboard verde y fondo claro con acciones y conteos del historial real; sin precisión inventada.
- Cámara/galería, vista previa y confirmación.
- RGB/EXIF/reescalado geométrico con contrato común. Sin normalización externa.
- Preprocesamiento e inferencia mediante compute en isolate, con intérprete cerrado en finally.
- Verificación de SHA-256, forma, tipo y orden de clases.
- Resultado con categoría, barras por clase, duración total (incluye cargar intérprete y preprocesar), fecha y versión.
- Guardado explícito SQLite e imágenes privadas, detalle y borrado confirmado.
- Guía y limitaciones. No se presentan umbrales no calibrados como detección de objetos ajenos.
- Android mantiene ID del proyecto; nombre visible TomatoLens y mínimo API26.

## Entrenamiento v2

- Auditoría independiente y particiones por grupos guardadas en JSON.
- Semilla, configuración, verificación de cambios en datos y separación antes de los lotes.
- Aumento solo en train; pesos por clase.
- Entrenamiento de cabeza y ajuste fino opcional, BN congelada y tasa baja.
- Selección global por val_loss entre ambas fases, sin consultar test.
- Evaluación final por clase/macro, matriz y predicciones.
- Exportación float32 y prueba de paridad; sin cuantización apresurada.

## Qué se verificó y qué queda pendiente

- Seis pruebas Python del contrato, EXIF, grupos, duplicados/conflictos y serialización: aprobadas.
- Ruff: aprobado.
- Pipeline de preparación, entrenamiento de cabeza y ajuste fino probado con 60 imágenes de ruido SINTÉTICO (42/9/9). Se usa exclusivamente para verificar ejecución, no como evidencia agronómica.
- Revisión sintáctica/formato Dart: realizada. Pruebas Flutter añadidas, pero NO ejecutadas.
- Flutter analyze/build/test y Android físico: pendientes. El arranque de Flutter fue bloqueado automáticamente al intentar consultar metadatos del entorno.
- Entrenamiento completo v2: pendiente de ejecutar en la laptop con las 4500 imágenes.
- No se prometen mejoras de exactitud del v2 hasta medirlas.
- iOS, firma de distribución, validación de campo, calibración y rechazo de imágenes ajenas: fuera de esta verificación.

## Documentación de referencia

- https://www.tensorflow.org/tutorials/images/transfer_learning
- https://pub.dev/packages/tflite_flutter/versions/0.11.0
- https://pub.dev/documentation/image/latest/image/bakeOrientation.html

## Entorno de verificación ML

Python 3.11.17, TensorFlow CPU 2.15.1, Keras 2.15.0. No se recibió la lista de versiones del equipo original; se fijó una línea base compatible con el modelo serializado.
