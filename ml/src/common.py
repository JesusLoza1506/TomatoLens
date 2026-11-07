"""Shared, versioned image contract: EXIF -> RGB -> half-pixel bilinear -> float32 0..255."""

from pathlib import Path
import hashlib
import json

import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[2]
LABELS = ["early_blight", "healthy", "late_blight"]
SIZE = 224


def _json_value(value):
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return value.tolist()
    raise TypeError(f"Unsupported JSON value: {type(value).__name__}")


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, default=_json_value), encoding="utf-8")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pixel_sha256(image):
    rgb = ImageOps.exif_transpose(image).convert("RGB")
    return hashlib.sha256(str(rgb.size).encode() + rgb.tobytes()).hexdigest()


def resize_rgb(array, size=SIZE):
    """Same half-pixel sampling in Dart; no extra normalization outside model."""
    h, w = array.shape[:2]
    yy = np.clip((np.arange(size) + 0.5) * h / size - 0.5, 0, h - 1)
    xx = np.clip((np.arange(size) + 0.5) * w / size - 0.5, 0, w - 1)
    y0, x0 = yy.astype(int), xx.astype(int)
    y1, x1 = np.minimum(y0 + 1, h - 1), np.minimum(x0 + 1, w - 1)
    wy, wx = (yy - y0)[:, None, None], (xx - x0)[None, :, None]
    a = array.astype(np.float32)
    out = (a[y0[:, None], x0] * (1 - wx) + a[y0[:, None], x1] * wx) * (1 - wy)
    out += (a[y1[:, None], x0] * (1 - wx) + a[y1[:, None], x1] * wx) * wy
    return out.astype(np.float32)


def load_image(path):
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        return resize_rgb(np.asarray(im))


def load_keras_model(path):
    """Keras 2.15 Windows archives can contain backslashes in HDF5 layer keys.

    Normalize only a temporary copy when loading such archives on POSIX.
    Original weights/configuration are never edited.
    """
    import os
    import io
    import tempfile
    import zipfile
    import h5py
    import tensorflow as tf

    if os.name == "nt":
        return tf.keras.models.load_model(path, compile=False)
    with zipfile.ZipFile(path) as z:
        weights = z.read("model.weights.h5")
        with h5py.File(io.BytesIO(weights), "r") as source:
            if not any("\\" in k for k in source):
                return tf.keras.models.load_model(path, compile=False)
            buffer = io.BytesIO()
            with h5py.File(buffer, "w") as dest:

                def copy(name, obj):
                    target = name.replace("\\", "/")
                    new = (
                        dest.require_group(target)
                        if isinstance(obj, h5py.Group)
                        else dest.create_dataset(target, data=obj[()])
                    )
                    for k, v in obj.attrs.items():
                        new.attrs[k] = v

                source.visititems(copy)
            fixed_weights = buffer.getvalue()
        with tempfile.TemporaryDirectory() as temp:
            fixed_path = Path(temp) / "compatible.keras"
            with zipfile.ZipFile(fixed_path, "w") as fixed:
                for name in z.namelist():
                    fixed.writestr(name, fixed_weights if name == "model.weights.h5" else z.read(name))
            return tf.keras.models.load_model(fixed_path, compile=False)
