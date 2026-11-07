# Cierre de TomatoLens

## Qué cambia en esta actualización

- Valida tamaño, formato y lectura antes de ofrecer el análisis. Cámara/galería,
  vista previa y confirmación mantienen el modelo en el dispositivo.
- Añade guardado sin foto, guardado automático por consentimiento, filtro por
  resultado y paginación. SQLite migra v1 a v2 sin descartar registros.
- El exportador de una nueva corrida exige una evaluación del mismo modelo y de
  las mismas particiones. El informe y las muestras quedan vinculados por huellas.
- El paquete no incluye pesos recién entrenados. Los assets preliminares y el APK
  compilado previamente se conservan hasta una nueva exportación y compilación.

## 1. Entrenar y evaluar en Windows

Abre PowerShell en `C:\Users\lozay\TomatoLens`. Usa el entorno de Python 3.11
del proyecto y ejecuta **un comando a la vez**, verificando su salida.
Si ya existe una partición auditada, consérvala; no la regeneres para buscar mejores resultados.

```powershell
Set-Location 'C:\Users\lozay\TomatoLens'
$py = '.\ml\.venv\Scripts\python.exe'
& $py -m pip install -r ml/requirements.txt
& $py -m pytest ml/tests -q
& $py ml/src/prepare_data.py
& $py ml/src/train.py
& $py ml/src/calibrate.py
& $py ml/src/evaluate.py
& $py ml/src/export_tflite.py --output ml/artifacts/v2/mobile_candidate
```

Si el entorno está en la raíz, usa `$py = '.\.venv\Scripts\python.exe'`.
Si aún no existe: `py -3.11 -m venv ml\.venv`.

Revisa `ml/data/processed/data_audit.json` antes de entrenar. El código no modifica
`ml/data/raw`. Si aparecen archivos dañados o etiquetas conflictivas, revisa esos
casos y documenta cómo se resolvieron. La división 70/15/15 es aproximada y conserva
grupos relacionados. Verifica los conteos por clase y registra la fuente, versión
y licencia de tu copia de PlantVillage.

`calibrate.py` usa **validación**, con objetivos propuestos de exactitud entre
casos aceptados de 95 % y cobertura de 70 %. Si no encuentra un umbral que satisfaga
ambos, no crea la política: esto es un resultado que debe quedar documentado.
La política no representa una probabilidad diagnóstica ni identifica por sí sola
imágenes de otros cultivos. No ajustes el umbral mirando test. Revisa la exactitud,
F1 por clase, F1 macro, matriz, predicciones equivocadas y, si hubo política, su
cobertura y exactitud en test.

La primera exportación va a una carpeta de candidato y no sustituye el modelo
preliminar incluido en Flutter. Revisa que `evaluation.json` corresponda al modelo
y que las métricas sean defendibles. Una vez elegido el candidato, copia juntos
`tomatolens_v1.tflite`, `labels.json` y `model_metadata.json`:

```powershell
Copy-Item ml/artifacts/v2/mobile_candidate/* frontend/assets/models/
```

Si ya existe un experimento en `ml/artifacts/v2`, conserva sus archivos y usa
`--output` en entrenamiento y `--experiment` en los comandos que correspondan.
Para exportar un experimento alternativo, indica su `--model` y `--output` de forma
explícita. Conserva la partición original para las comparaciones.

## 2. Fotografías de campo

Prepara un CSV con columnas `path,label` y rutas relativas a tu carpeta de fotos.
Etiquetas: `healthy`, `early_blight`, `late_blight` y `other`. Haz revisar las
etiquetas y mantén este conjunto aparte. No uses las fotos de la evaluación externa
para ajustar el umbral que vas a reportar.

```powershell
& $py ml/src/evaluate_external.py --photos C:\ruta\a\fotos --labels C:\ruta\a\etiquetas.csv
```

`external_evaluation.json` mantiene los resultados externos separados de PlantVillage.
Indica el tamaño real de la muestra y presenta sus resultados como exploratorios.

## 3. Validación en Android y entrega

Desde la raíz, genera la prueba de paridad para el modelo activo. La tolerancia
móvil inicial es 0,01 de diferencia absoluta por puntuación y exige la misma clase
ganadora. Documenta cualquier divergencia; no ajustes la tolerancia solo para
hacer pasar la prueba.

```powershell
# Si Flutter todavía trae legacy-v1:
& $py ml/src/prepare_mobile_parity.py

# Si Flutter ya trae el candidato v2:
& $py ml/src/prepare_mobile_parity.py --reference ml/artifacts/v2/export_parity.json

Set-Location frontend
flutter pub get
dart format lib test integration_test/history_sqlite_test.dart
flutter analyze
flutter test
flutter devices
flutter test integration_test/history_sqlite_test.dart -d ID_DEL_ANDROID
flutter test integration_test/native_parity_generated_test.dart -d ID_DEL_ANDROID
flutter build apk --release
```

Ejecuta solo uno de los dos comandos de generación. Sustituye `ID_DEL_ANDROID`
por el identificador de `flutter devices`. El test de paridad genera un archivo
local excluido de Git; sus fotos de referencia se incluyen solo en el APK de prueba.

En el APK release instalado y en modo avión, verifica: abrir, cámara/galería,
cancelar, archivo inválido, permiso denegado, resultado, guardar con y sin foto,
reabrir, consultar y borrar. Prueba también una pantalla pequeña y letra grande.
Para el reporte de rendimiento, registra dispositivo y versión de Android, modo de
compilación, tamaño del APK y una serie de mediciones: arranque, memoria y latencia
mediana/P95. Separa la primera inferencia de las mediciones posteriores.

Para la entrega conserva: auditoría y particiones, configuración e historiales,
selección del modelo, evaluación de PlantVillage, evaluación externa, referencia
de paridad, resultados de Android y CI, y una demo breve. Publicar en una tienda
y validar iOS no forman parte del cierre académico de Android.
