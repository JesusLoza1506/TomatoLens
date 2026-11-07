# TomatoLens para Android

App Flutter para analizar una foto de hoja de tomate sin conexión. Devuelve
puntuaciones para hoja sana, tizón temprano y tizón tardío. El resultado es orientativo.

## Ejecutar desde frontend

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK: `build\app\outputs\flutter-apk\app-release.apk`.
Para la demo de clase, el proyecto conserva su configuración de firma de desarrollo.
No uses esa firma como credencial para publicar en una tienda.

## Flujo y almacenamiento

- Abre **Analizar**, elige cámara o galería, revisa la imagen y confirma.
- El historial carga 20 registros por página y permite filtrar por resultado.
- En **Guía** puedes desactivar la conservación de fotos. Los resultados se guardan
  manualmente salvo que actives el guardado automático.
- La actualización de SQLite conserva los registros y fotos de la versión anterior.
- El resultado **No concluyente** requiere que el modelo distribuido incluya una
  política ajustada en validación y comprobada en test. La versión preliminar no
  trae un umbral, y ningún umbral garantiza detectar fotos ajenas.

## Pruebas en Android

```powershell
flutter devices
flutter test integration_test/history_sqlite_test.dart -d ID_DEL_ANDROID
```

La prueba usa una base temporal: verifica migración, guardado sin foto, paginación,
preferencias, reapertura y borrado. Para las pruebas de paridad del modelo, consulta
`../docs/CIERRE_TOMATOLENS.md`.
