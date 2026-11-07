"""Export float32 + labels + checksum + explicit contract; verify Keras/TFLite parity."""

import argparse
from pathlib import Path

import numpy as np
import tensorflow as tf

from common import load_keras_model, LABELS, ROOT, load_image, sha256, write_json
from decision import threshold_from_report
from experiment import experiment_identity, read_json, require_matching_report


def export(model_path, output, samples, legacy=False):
    metadata = {}
    if not legacy:
        identity = experiment_identity(model_path)
        report_path = model_path.parent / "evaluation.json"
        if not report_path.exists():
            raise ValueError("Primero ejecuta evaluate.py para el modelo seleccionado.")
        report = require_matching_report(report_path, identity, "test")
        if not report.get("test_images"):
            raise ValueError("El informe no contiene un conjunto de prueba evaluado.")
        metadata.update(identity, evaluation_sha256=sha256(report_path))
        policy_path = model_path.parent / "decision_policy.json"
        if policy_path.exists():
            policy = require_matching_report(policy_path, identity, "validation")
            threshold = threshold_from_report(policy)
            if not report.get("decision_policy_on_test"):
                raise ValueError("La evaluación no incluye la política de decisión.")
            if report.get("decision_policy_sha256") != sha256(policy_path):
                raise ValueError("La evaluación no corresponde a la política exportada.")
            metadata["decision_policy"] = {"min_score": threshold, "validation_policy_sha256": sha256(policy_path)}
        elif report.get("decision_policy_sha256"):
            raise ValueError("Falta la política de decisión evaluada.")
    model = load_keras_model(model_path)
    rescale = next(layer for layer in model.layers if isinstance(layer, tf.keras.layers.Rescaling))
    expected_scale, expected_offset = (1 / 255, 0) if legacy else (1 / 127.5, -1)
    cfg = rescale.get_config()
    if not np.isclose(cfg["scale"], expected_scale) or cfg["offset"] != expected_offset:
        raise ValueError("El preprocesamiento del modelo no corresponde al modo indicado.")
    label_path = model_path.parent / "labels.json"
    if not label_path.exists() and not legacy:
        raise ValueError("Falta labels.json del entrenamiento.")
    labels = read_json(label_path) if label_path.exists() else LABELS
    if labels != LABELS:
        raise ValueError("Orden de etiquetas incompatible.")
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converted = converter.convert()
    interp = tf.lite.Interpreter(model_content=converted, num_threads=2)
    interp.allocate_tensors()
    rows = []
    files = sorted(p for p in samples.glob("*/*") if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
    if not files:
        raise ValueError("Se requieren imágenes --samples para validar paridad antes de exportar.")
    for path in files:
        tensor = load_image(path)[None]
        keras_scores = model(tensor, training=False).numpy()[0]
        interp.set_tensor(interp.get_input_details()[0]["index"], tensor)
        interp.invoke()
        mobile_scores = interp.get_tensor(interp.get_output_details()[0]["index"])[0]
        if not np.isfinite(keras_scores).all() or not np.isfinite(mobile_scores).all():
            raise ValueError(f"Puntuaciones no finitas: {path.name}")
        delta = float(np.max(abs(keras_scores - mobile_scores)))
        if delta > 1e-4 or keras_scores.argmax() != mobile_scores.argmax():
            raise ValueError(f"Paridad fallida: {path.name}: {delta}")
        rows.append(
            dict(file=path.name, file_sha256=sha256(path), max_abs_difference=delta, scores=mobile_scores.tolist())
        )
    parity_path = model_path.parent / "export_parity.json"
    write_json(parity_path, rows)
    output.mkdir(parents=True, exist_ok=True)
    tflite_path = output / "tomatolens_v1.tflite"
    tflite_path.write_bytes(converted)
    write_json(output / "labels.json", labels)
    write_json(
        output / "model_metadata.json",
        dict(
            model_version="legacy-v1" if legacy else f"mobilenet-v2-{metadata['model_sha256'][:12]}",
            input_shape=[1, 224, 224, 3],
            input_dtype="float32",
            input_range=[0, 255],
            color_order="RGB",
            resize="half_pixel_bilinear_v1",
            internal_rescaling=dict(scale=expected_scale, offset=expected_offset),
            labels=labels,
            sha256=sha256(tflite_path),
            parity_reference_sha256=sha256(parity_path),
            independently_evaluated=not legacy,
            **metadata,
            note="Modelo inicial corregido en integración; pendiente reentrenamiento."
            if legacy
            else "Consultar evaluation.json del experimento; el score Softmax no es certeza diagnóstica.",
        ),
    )
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", type=Path, default=ROOT / "ml/artifacts/v2/model.keras")
    p.add_argument("--output", type=Path, default=ROOT / "frontend/assets/models")
    p.add_argument("--samples", type=Path, default=ROOT / "ml/samples")
    p.add_argument("--legacy", action="store_true")
    a = p.parse_args()
    rows = export(a.model, a.output, a.samples, a.legacy)
    print(f"Exportación verificada en {len(rows)} muestras. Flutter debe enviar RGB 0..255 SIN normalizar.")


if __name__ == "__main__":
    main()
