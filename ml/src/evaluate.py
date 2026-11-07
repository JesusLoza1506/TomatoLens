"""Final sealed-test evaluation. No fitting/calibration/model selection here."""

import argparse
import json
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from sklearn.metrics import ConfusionMatrixDisplay, classification_report, confusion_matrix

from common import load_keras_model, LABELS, ROOT, sha256, write_json
from experiment import experiment_identity, load_rows, verify_pixels
from train import dataset


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", type=Path, default=ROOT / "ml/artifacts/v2")
    p.add_argument("--data", type=Path, default=ROOT / "ml/data/raw")
    a = p.parse_args()
    model_path = a.experiment / "model.keras"
    identity = experiment_identity(model_path)
    rows = [r for r in load_rows(a.experiment / "splits.json") if r["split"] == "test"]
    verify_pixels(rows, a.data)
    ds = dataset(rows, a.data, False, 32)
    model = load_keras_model(model_path)
    scores = model.predict(ds)
    if scores.shape != (len(rows), 3) or not np.isfinite(scores).all():
        raise ValueError("El modelo no produjo un vector válido por imagen de prueba.")
    truth = [LABELS.index(r["label"]) for r in rows]
    pred = scores.argmax(axis=1)
    report = classification_report(
        truth, pred, labels=[0, 1, 2], target_names=LABELS, output_dict=True, zero_division=0
    )
    report["test_images"] = len(rows)
    report["identity"] = identity
    report["split"] = "test"
    policy_path = a.experiment / "decision_policy.json"
    if policy_path.exists():
        from decision import acceptance_summary, threshold_from_report
        from experiment import require_matching_report

        policy = require_matching_report(policy_path, identity, "validation")
        report["decision_policy_sha256"] = sha256(policy_path)
        report["decision_policy_on_test"] = acceptance_summary(
            scores.max(axis=1), pred == truth, threshold_from_report(policy)
        )
    report["scope"] = "Partición PlantVillage; no mide generalización en campo."
    write_json(
        a.experiment / "test_predictions.json",
        [
            dict(path=r["path"], truth=r["label"], predicted=LABELS[int(k)], scores=s.tolist())
            for r, k, s in zip(rows, pred, scores)
        ],
    )
    cm = confusion_matrix(truth, pred, labels=[0, 1, 2])
    ConfusionMatrixDisplay(cm, display_labels=LABELS).plot(cmap="Greens", xticks_rotation=25)
    plt.tight_layout()
    plt.savefig(a.experiment / "confusion_matrix.png", dpi=160)
    plt.close()
    write_json(a.experiment / "evaluation.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
