"""Reproducible MobileNetV2 training. Test remains sealed until evaluate.py."""

import argparse
from pathlib import Path

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers

from common import LABELS, ROOT, load_image, write_json
from experiment import load_rows, read_json
from prepare_data import audit


def dataset(rows, raw, training, batch):
    paths = [str(raw / r["path"]) for r in rows]
    labels = [LABELS.index(r["label"]) for r in rows]
    ds = tf.data.Dataset.from_tensor_slices((paths, labels))
    if training:
        ds = ds.shuffle(len(paths), seed=42, reshuffle_each_iteration=True)

    def decode(path, label):
        def read(p):
            return load_image(p.numpy().decode())

        image = tf.py_function(read, [path], tf.float32)
        image.set_shape((224, 224, 3))
        return image, label

    ds = ds.map(decode, num_parallel_calls=2).batch(batch)
    if training:
        augment = tf.keras.Sequential(
            [
                layers.RandomFlip("horizontal", seed=42),
                layers.RandomRotation(0.06, seed=43),
                layers.RandomZoom(0.08, seed=44),
            ]
        )
        ds = ds.map(lambda x, y: (augment(x, training=True), y), num_parallel_calls=2)
    return ds.prefetch(1)  # No unbounded RAM cache of float32 images/batches.


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", type=Path, default=ROOT / "ml/data/raw")
    p.add_argument("--splits", type=Path, default=ROOT / "ml/data/processed/splits.json")
    p.add_argument("--output", type=Path, default=ROOT / "ml/artifacts/v2")
    p.add_argument("--epochs", type=int, default=15)
    p.add_argument("--fine-tune-epochs", type=int, default=5)
    p.add_argument("--batch-size", type=int, default=32)
    a = p.parse_args()
    if a.output.exists() and any(a.output.iterdir()):
        raise SystemExit("Usa un --output nuevo para no sobrescribir un experimento.")
    tf.keras.utils.set_random_seed(42)
    tf.config.experimental.enable_op_determinism()
    manifest = read_json(a.splits)
    rows = load_rows(a.splits)
    # Verify that no files were changed after auditing/splitting.
    current, audit_report = audit(a.data.resolve(), near_distance=0)
    expected = {r["path"]: r["sha256"] for r in manifest["rows"]}
    if audit_report["unreadable"] or {r["path"]: r["sha256"] for r in current} != expected:
        raise ValueError("Dataset modificado después de preparar las particiones.")
    train_rows = [r for r in rows if r["split"] == "train"]
    val_rows = [r for r in rows if r["split"] == "validation"]
    train = dataset(train_rows, a.data, True, a.batch_size)
    val = dataset(val_rows, a.data, False, a.batch_size)
    base = tf.keras.applications.MobileNetV2(include_top=False, weights="imagenet", input_shape=(224, 224, 3))
    base.trainable = False
    inputs = tf.keras.Input((224, 224, 3), name="rgb_0_255")
    x = layers.Rescaling(1 / 127.5, offset=-1, name="mobilenet_normalization")(inputs)
    x = base(x, training=False)
    x = layers.GlobalAveragePooling2D()(x)
    x = layers.Dropout(0.25, seed=42)(x)
    outputs = layers.Dense(3, activation="softmax", name="scores")(x)
    model = tf.keras.Model(inputs, outputs)
    counts = np.bincount([LABELS.index(r["label"]) for r in train_rows], minlength=3)
    weights = {i: float(len(train_rows) / (3 * n)) for i, n in enumerate(counts)}
    a.output.mkdir(parents=True)
    write_json(a.output / "labels.json", LABELS)
    write_json(a.output / "splits.json", manifest)
    write_json(
        a.output / "training_config.json",
        dict(
            epochs=a.epochs,
            fine_tune_epochs=a.fine_tune_epochs,
            batch_size=a.batch_size,
            seed=42,
            tensorflow=tf.__version__,
            class_weights=weights,
            learning_rate_head=1e-3,
            learning_rate_finetune=1e-5,
            finetune_candidate_layers=20,
            monitor="val_loss",
            early_stopping_patience=4,
            augmentation=dict(flip="horizontal", rotation=0.06, zoom=0.08),
            preprocessing="RGB float32 0..255, half_pixel_bilinear_v1; internal x/127.5-1",
        ),
    )

    def callbacks(name):
        return [
            tf.keras.callbacks.ModelCheckpoint(
                str(a.output / f"{name}.keras"), monitor="val_loss", save_best_only=True
            ),
            tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=4, restore_best_weights=True),
            tf.keras.callbacks.ReduceLROnPlateau(monitor="val_loss", patience=2, factor=0.5, min_lr=1e-6),
        ]

    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3), loss="sparse_categorical_crossentropy", metrics=["accuracy"]
    )
    h = model.fit(train, validation_data=val, epochs=a.epochs, class_weight=weights, callbacks=callbacks("head_best"))
    write_json(a.output / "history_head.json", h.history)
    model = tf.keras.models.load_model(a.output / "head_best.keras")
    best_loss = float(model.evaluate(val, verbose=0)[0])
    best_path = a.output / "head_best.keras"
    fine_loss = None
    if a.fine_tune_epochs:
        backbone = next(layer for layer in model.layers if isinstance(layer, tf.keras.Model))
        backbone.trainable = True
        for layer in backbone.layers[:-20]:
            layer.trainable = False
        for layer in backbone.layers:
            if isinstance(layer, layers.BatchNormalization):
                layer.trainable = False
        model.compile(
            optimizer=tf.keras.optimizers.Adam(1e-5), loss="sparse_categorical_crossentropy", metrics=["accuracy"]
        )
        h = model.fit(
            train,
            validation_data=val,
            epochs=a.fine_tune_epochs,
            class_weight=weights,
            callbacks=callbacks("finetune_best"),
        )
        write_json(a.output / "history_finetune.json", h.history)
        candidate = tf.keras.models.load_model(a.output / "finetune_best.keras")
        fine_loss = float(candidate.evaluate(val, verbose=0)[0])
        if fine_loss < best_loss:
            best_path = a.output / "finetune_best.keras"
    tf.keras.models.load_model(best_path, compile=False).save(a.output / "model.keras")
    write_json(
        a.output / "selection.json",
        dict(checkpoint=best_path.name, monitor="val_loss", head_val_loss=best_loss, finetune_val_loss=fine_loss),
    )
    print(
        f"Mejor modelo por val_loss: {best_path.name}. Test NO utilizado. Ejecuta evaluate.py cuando cierres los ajustes."
    )


if __name__ == "__main__":
    main()
