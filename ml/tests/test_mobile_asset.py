"""Smoke test for the TFLite asset distributed with the Android app."""

import hashlib
import json
from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image, ImageOps


ROOT = Path(__file__).resolve().parents[2]


def test_bundled_tflite_can_classify_an_rgb_image():
    assets = ROOT / "frontend" / "assets" / "models"
    model = assets / "tomatolens_v1.tflite"
    metadata = json.loads((assets / "model_metadata.json").read_text(encoding="utf-8-sig"))
    labels = json.loads((assets / "labels.json").read_text(encoding="utf-8-sig"))

    assert labels == metadata["labels"] == ["early_blight", "healthy", "late_blight"]
    assert metadata["input_shape"] == [1, 224, 224, 3]
    assert metadata["input_dtype"] == "float32"
    assert metadata["input_range"] == [0, 255]
    assert metadata["color_order"] == "RGB"
    assert hashlib.sha256(model.read_bytes()).hexdigest() == metadata["sha256"], "TFLite y metadata no coinciden"

    interpreter = tf.lite.Interpreter(model_path=str(model), num_threads=1)
    interpreter.allocate_tensors()
    (input_info,) = interpreter.get_input_details()
    (output_info,) = interpreter.get_output_details()
    assert input_info["shape"].tolist() == metadata["input_shape"]
    assert input_info["dtype"] == np.float32
    assert output_info["shape"].tolist() == [1, len(labels)]
    assert output_info["dtype"] == np.float32

    fixtures = ROOT / "ml" / "samples" / "healthy"
    photos = sorted(p for p in fixtures.glob("*") if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg"})
    assert photos, "Incluye una foto JPG de prueba en ml/samples/healthy"
    with Image.open(photos[0]) as image:
        rgb = ImageOps.exif_transpose(image).convert("RGB").resize((224, 224), Image.Resampling.BILINEAR)
        sample = np.asarray(rgb, dtype=np.float32)[None, ...]

    interpreter.set_tensor(input_info["index"], sample)
    interpreter.invoke()
    probabilities = interpreter.get_tensor(output_info["index"])[0]
    assert np.isfinite(probabilities).all()
    assert ((probabilities >= 0) & (probabilities <= 1)).all()
    np.testing.assert_allclose(probabilities.sum(), 1.0, atol=1e-4)
