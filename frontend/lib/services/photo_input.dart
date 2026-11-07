import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

class PhotoProblem implements Exception {
  const PhotoProblem(this.message);
  final String message;
}

class PhotoInput {
  PhotoInput({ImagePicker? picker}) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  Future<XFile?> pick(ImageSource source) => _picker.pickImage(source: source);

  Future<XFile?> recover() async {
    final response = await _picker.retrieveLostData();
    if (response.exception != null) throw response.exception!;
    final files = response.files;
    return files == null || files.isEmpty ? null : files.first;
  }

  Future<Uint8List> read(XFile file) async {
    if (await file.length() > 25 * 1024 * 1024) {
      throw const PhotoProblem('La imagen supera 25 MB. Elige una foto más pequeña.');
    }
    final bytes = await file.readAsBytes();
    final jpg = bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255;
    const pngMagic = [137, 80, 78, 71, 13, 10, 26, 10];
    final png = bytes.length >= pngMagic.length &&
        List.generate(pngMagic.length, (i) => bytes[i] == pngMagic[i]).every((ok) => ok);
    if (!jpg && !png) {
      throw const PhotoProblem('Formato no compatible. Elige una foto JPG o PNG.');
    }
    // Python and Dart use the same RGB8 contract; reject 16-bit PNG inputs.
    if (png && bytes.length > 24 && bytes[24] > 8) {
      throw const PhotoProblem('Exporta la imagen como PNG de 8 bits o JPG.');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width < 64 || descriptor.height < 64 ||
            descriptor.width * descriptor.height > 24000000) {
          throw const PhotoProblem(
            'Elige una foto de al menos 64 × 64 píxeles y hasta 24 megapíxeles.',
          );
        }
      } finally {
        descriptor.dispose();
      }
    } on PhotoProblem {
      rethrow;
    } catch (_) {
      throw const PhotoProblem('La foto está dañada o no se pudo leer.');
    } finally {
      buffer.dispose();
    }
    if (!await compute(_isDecodable, bytes)) {
      throw const PhotoProblem('La foto está dañada o no se pudo leer.');
    }
    return bytes;
  }
}

bool _isDecodable(Uint8List bytes) {
  try {
    return img.decodeImage(bytes) != null;
  } catch (_) {
    return false;
  }
}
