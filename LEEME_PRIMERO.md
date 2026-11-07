# TomatoLens · actualización de modelo, integración e interfaz

Esta entrega se aplica SOBRE tu proyecto actual en `C:\Users\lozay\TomatoLens`.
No contiene todo el esqueleto generado por Flutter. No elimines ni sustituyas la
carpeta completa del proyecto. El dataset raw no está incluido ni se modifica.

## 1. Aplicar actualización

1. Cierra la app y detén `flutter run`.
2. Extrae este ZIP en Descargas, separado del proyecto original.
3. Abre PowerShell en la carpeta que contiene este archivo y ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Actualizar-Proyecto.ps1 -Proyecto "C:\Users\lozay\TomatoLens"
```

La opción Bypass solo afecta ese proceso; no cambia la política permanente.
El script crea una copia de los archivos reemplazados junto al proyecto y conserva
el esqueleto Android/iOS y tus 4500 imágenes. También puedes copiar manualmente el
contenido sobre el proyecto, después de hacer una copia de seguridad.

## 2. Probar primero la app corregida, SIN reentrenar

```powershell
cd C:\Users\lozay\TomatoLens\frontend
flutter pub get
flutter analyze
flutter test
flutter run
```

Selecciona un dispositivo Android. Android mínimo: 8.0/API 26.
`pub get` actualizará el lockfile según las nuevas dependencias SQLite/rutas/crypto.
La app muestra Inicio, Analizar, Historial y Guía. Elige una imagen, confirma la
vista previa y guarda el resultado si quieres conservarlo. Cámara y galería usan
el selector/plugin del sistema. Borrado individual y vaciado piden confirmación.

**El modelo incluido conserva los pesos del entrenamiento inicial**, exportados
nuevamente y comprobados. Se etiqueta `legacy-v1`. No se le cambió el reescalado
interno, porque eso alteraría el contrato aprendido sin reentrenar. La app ahora
le entrega RGB float32 0..255, sin volver a dividir por 255.

## 3. Preparar el entrenamiento v2 con el dataset COMPLETO

Se recomienda Python 3.11. Comprueba tu entorno existente antes de reemplazarlo:

```powershell
cd C:\Users\lozay\TomatoLens
python --version
python -m pip install -r ml\requirements.txt
python -m pytest ml\tests -q
python -m ruff check ml
python ml\src\prepare_data.py
```

Si tu Python no es 3.11, crea un entorno aparte, sin borrar el anterior:

```powershell
py -3.11 -m venv ml\.venv-v2
.\ml\.venv-v2\Scripts\Activate.ps1
python -m pip install -r ml\requirements.txt
```

Las imágenes deben seguir en:
- `ml/data/raw/early_blight`
- `ml/data/raw/healthy`
- `ml/data/raw/late_blight`

Preparación crea `ml/data/processed/data_audit.json` y `splits.json`:
- lectura completa de archivos, EXIF y RGB;
- detección de duplicados por píxeles decodificados;
- agrupación por identificadores de hoja disponibles en nombres y similitud dHash;
- separación aproximada 70/15/15 POR CATEGORÍA y sin grupos compartidos;
- error ante imágenes dañadas o posibles conflictos de etiquetas para revisión.

No se borra ni mueve ninguna imagen. Si hay conflictos, revisa el informe antes
de seguir; no elimines ejemplos solo para mejorar una métrica. dHash es una
heurística: puede agrupar fotos diferentes y puede omitir relaciones. La revisión
manual sigue siendo necesaria. Los porcentajes exactos pueden variar por grupos.

Si ya existe `splits.json`, se detiene para proteger el conjunto de prueba. Un
nuevo dataset debe usar otro `--output` y el entrenamiento su `--splits` asociado.
No regeneres particiones entre experimentos para buscar mejores resultados.

## 4. Entrenamiento corto para comprobar el pipeline

```powershell
python ml\src\train.py --epochs 5 --fine-tune-epochs 0 --output ml\artifacts\prueba_v2
```

Este comando usa tus datos completos; no usa `ml/samples` como dataset de
entrenamiento. Las nueve muestras sirven únicamente para comprobar la integración.

## 5. Entrenamiento principal

```powershell
python ml\src\train.py --epochs 15 --fine-tune-epochs 5
```

Usa MobileNetV2 ImageNet, reescalado INTERNO `x/127.5 - 1`, aumento de datos solo en
train, pesos por clase, EarlyStopping, ReduceLROnPlateau y checkpoints por val_loss.
La base se congela primero. El ajuste fino abre las últimas 20 capas y mantiene
BatchNormalization congelada y en modo inferencia. Se compara el mejor checkpoint
congelado y el mejor de ajuste fino; solo se publica el de menor pérdida de
validación. Test no interviene en `fit` ni en la elección.

Los parámetros predeterminados son una línea base, no una garantía de rendimiento.
No hay caché en RAM de miles de imágenes ni shuffle de 1000 lotes.
Los archivos quedan en `ml/artifacts/v2` sin sobrescribir el modelo inicial.
Si repites el experimento, indica otra ruta `--output`.

## 6. Evaluación final y exportación

Tras cerrar tus decisiones de entrenamiento, evalúa UNA vez el test reservado:

```powershell
python ml\src\evaluate.py
python ml\src\export_tflite.py
```

La evaluación escribe métricas por clase, macro F1, matriz de confusión y
predicciones. La exportación compara Keras/TFLite en las nueve muestras con
máxima diferencia permitida 0.0001 y misma categoría ganadora antes de escribir
el modelo, etiquetas y metadatos en los assets. Las nueve imágenes pueden haber
participado en el entrenamiento original: NO son evidencia independiente.

**Después de exportar, detén y vuelve a ejecutar `flutter run`** para que se
empaquete el nuevo modelo. No uses solo hot reload. No mezcles el TFLite de un
experimento con etiquetas/metadatos de otro: la app valida el checksum.

## 7. Entrega y comprobaciones Android pendientes

```powershell
cd frontend
flutter analyze
flutter test
flutter build apk --debug
```

Prueba cámara, galería, cancelación, permiso denegado, archivo inválido, guardado,
reapertura, borrado, modo avión y las nueve muestras. El APK debug es de pruebas.
No se cambió a una firma de producción: tu Gradle original firma release con la
clave debug; antes de publicar en una tienda configura una clave propia.

La compilación y las pruebas Flutter no se ejecutaron en el entorno de revisión:
el arranque de Flutter fue bloqueado por la revisión automática de seguridad
al intentar consultar el servicio de metadatos del entorno. Solo se verificó
sintaxis/formato Dart y se revisaron las APIs empleadas. Ejecuta los comandos
anteriores en tu laptop y comparte cualquier error.

Se conservó la configuración Android que enviaste salvo nombre visible y mínimo
API 26. iOS no está validado: necesitará macOS, configuración de cámara/fototeca
en Info.plist y pruebas específicas. La entrega principal sigue siendo Android.
