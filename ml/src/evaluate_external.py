"""Evaluate reviewed field photographs separately from the PlantVillage test."""

import argparse
import csv
from pathlib import Path

import numpy as np
from PIL import Image
from sklearn.metrics import classification_report

from common import LABELS, ROOT, load_image, load_keras_model, pixel_sha256, sha256, write_json
from decision import acceptance_summary, threshold_from_report
from experiment import experiment_identity, load_rows, require_matching_report

OTHER = "other"


def read_photos(csv_path, photos, known_hashes):
    seen = set(known_hashes)
    rows = []
    with csv_path.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            path = (photos / row["path"]).resolve()
            label = row["label"].strip()
            if not path.is_relative_to(photos) or label not in (*LABELS, OTHER):
                raise ValueError("Cada fila requiere una ruta dentro de --photos y una etiqueta válida.")
            with Image.open(path) as image:
                digest = pixel_sha256(image)
            if digest in seen:
                raise ValueError(f"Imagen duplicada o ya presente en PlantVillage: {row['path']}")
            seen.add(digest)
            rows.append((path, label))
    if not any(label != OTHER for _, label in rows):
        raise ValueError("Incluye fotos etiquetadas de al menos una clase de tomate.")
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", type=Path, default=ROOT / "ml/artifacts/v2")
    p.add_argument("--photos", type=Path, required=True)
    p.add_argument("--labels", type=Path, required=True, help="CSV con columnas path,label")
    a = p.parse_args()
    model_path = a.experiment / "model.keras"
    identity = experiment_identity(model_path)
    evaluation = require_matching_report(a.experiment / "evaluation.json", identity, "test")
    known_hashes = {r["sha256"] for r in load_rows(a.experiment / "splits.json")}
    photos = a.photos.resolve()
    rows = read_photos(a.labels, photos, known_hashes)
    model = load_keras_model(model_path)
    scores = np.asarray([model(load_image(path)[None], training=False).numpy()[0] for path, _ in rows])
    if scores.shape != (len(rows), 3) or not np.isfinite(scores).all():
        raise ValueError("El modelo no produjo un vector válido por foto.")
    truth = np.array([label for _, label in rows])
    predicted = np.array(LABELS)[scores.argmax(axis=1)]
    top = scores.max(axis=1)
    tomato = truth != OTHER
    report = dict(
        identity=identity,
        labels_csv_sha256=sha256(a.labels),
        scope="Prueba exploratoria externa; independiente del reporte PlantVillage.",
        tomato_images=int(tomato.sum()),
        tomato_accuracy=float((truth[tomato] == predicted[tomato]).mean()),
        other_images=int((~tomato).sum()),
        tomato_metrics=classification_report(
            truth[tomato], predicted[tomato], labels=LABELS, output_dict=True, zero_division=0
        ),
    )
    policy = a.experiment / "decision_policy.json"
    threshold = None
    if policy.exists():
        if evaluation.get("decision_policy_sha256") != sha256(policy):
            raise ValueError("La política no coincide con la evaluada en test.")
        threshold = threshold_from_report(require_matching_report(policy, identity, "validation"))
        report["tomato_with_policy"] = acceptance_summary(top[tomato], predicted[tomato] == truth[tomato], threshold)
        report["other_accepted"] = int((top[~tomato] >= threshold).sum())
        report["other_acceptance_rate"] = float((top[~tomato] >= threshold).mean()) if (~tomato).any() else None
    report["predictions"] = [
        dict(
            path=path.relative_to(photos).as_posix(),
            label=label,
            predicted=predicted[i],
            scores=scores[i].tolist(),
            accepted=None if threshold is None else bool(top[i] >= threshold),
        )
        for i, (path, label) in enumerate(rows)
    ]
    output = a.experiment / "external_evaluation.json"
    write_json(output, report)
    print(f"Evaluación externa guardada: {output}")


if __name__ == "__main__":
    main()
