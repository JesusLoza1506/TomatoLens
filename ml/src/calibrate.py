"""Choose an optional abstention threshold without consulting the test partition."""

import argparse
from pathlib import Path

import numpy as np

from common import LABELS, ROOT, load_keras_model, write_json
from decision import choose_threshold
from experiment import experiment_identity, load_rows, verify_pixels
from train import dataset


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", type=Path, default=ROOT / "ml/artifacts/v2")
    p.add_argument("--data", type=Path, default=ROOT / "ml/data/raw")
    p.add_argument("--min-accuracy", type=float, default=0.95)
    p.add_argument("--min-coverage", type=float, default=0.70)
    a = p.parse_args()
    out = a.experiment / "decision_policy.json"
    if out.exists() or (a.experiment / "evaluation.json").exists():
        raise SystemExit("No se ajusta una política después de cerrar el experimento o consultar test.")
    rows = [r for r in load_rows(a.experiment / "splits.json") if r["split"] == "validation"]
    if len(rows) < 30:
        raise SystemExit("Se requieren al menos 30 ejemplos de validación para este protocolo.")
    verify_pixels(rows, a.data)
    model_path = a.experiment / "model.keras"
    identity = experiment_identity(model_path)
    scores = load_keras_model(model_path).predict(dataset(rows, a.data, False, 32))
    truth = np.asarray([LABELS.index(r["label"]) for r in rows])
    chosen = choose_threshold(scores.max(axis=1), scores.argmax(axis=1) == truth, a.min_accuracy, a.min_coverage)
    if chosen is None:
        print("Ningún umbral satisface ambos objetivos. No se generó una política.")
        return
    write_json(
        out,
        dict(
            identity=identity,
            split="validation",
            targets=dict(min_accuracy=a.min_accuracy, min_coverage=a.min_coverage),
            **chosen,
        ),
    )
    print(f"Política guardada: {out}. Aún falta medirla en test y en fotos externas.")


if __name__ == "__main__":
    main()
