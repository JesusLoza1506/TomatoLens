import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:frontend/services/classifier.dart';

void main() {
  test('Pixel values remain in 0..255: no second normalization', () {
    final image = img.Image(width: 2, height: 2)
      ..clear(img.ColorRgb8(255, 128, 0));
    final tensor = preprocessImage(Uint8List.fromList(img.encodePng(image)));
    expect(tensor.length, 224 * 224 * 3);
    expect(tensor[0], 255);
    expect(tensor[1], 128);
    expect(tensor[2], 0);
  });
  test('Half pixel bilinear matches Python reference', () {
    final image = img.Image(width: 2, height: 2);
    image.setPixelRgb(0, 0, 0, 0, 0);
    image.setPixelRgb(1, 0, 100, 100, 100);
    image.setPixelRgb(0, 1, 200, 200, 200);
    image.setPixelRgb(1, 1, 240, 240, 240);
    final tensor = preprocessImage(Uint8List.fromList(img.encodePng(image)));
    // Pixel at (112,112): fx=fy=0.5044642857142857.
    expect(tensor[(112 * 224 + 112) * 3], closeTo(136.0702328, 1e-4));
  });
  test('Invalid input fails clearly', () {
    expect(
      () => preprocessImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
