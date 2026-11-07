"""Fit a simple abstention rule on validation only; this is not an OOD detector."""

import numpy as np


def acceptance_summary(top_scores, correct, threshold):
    mask = np.asarray(top_scores) >= threshold
    correct = np.asarray(correct, dtype=bool)
    accepted = int(mask.sum())
    return {
        "total": len(mask),
        "accepted": accepted,
        "correct_accepted": int(correct[mask].sum()),
        "coverage": accepted / len(mask),
        "accuracy_when_accepted": float(correct[mask].mean()) if accepted else None,
    }


def choose_threshold(top_scores, correct, min_accuracy, min_coverage):
    top_scores = np.asarray(top_scores)
    if not len(top_scores) or not np.isfinite(top_scores).all():
        raise ValueError("Puntuaciones de validación inválidas.")
    if not (0 < min_accuracy <= 1 and 0 < min_coverage <= 1):
        raise ValueError("Los objetivos deben estar en (0, 1].")
    for threshold in sorted({0.0, *map(float, top_scores)}):
        summary = acceptance_summary(top_scores, correct, threshold)
        if (
            summary["accepted"]
            and summary["coverage"] >= min_coverage
            and summary["accuracy_when_accepted"] >= min_accuracy
        ):
            return {"min_score": threshold, **summary}
    return None


def threshold_from_report(report):
    threshold = report["min_score"]
    if not isinstance(threshold, (int, float)) or not 0 <= threshold <= 1:
        raise ValueError("Umbral fuera de rango.")
    return threshold
