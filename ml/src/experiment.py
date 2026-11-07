"""Check that data, evaluation and model describe the same experiment."""

import json
from pathlib import PurePosixPath

from PIL import Image

from common import LABELS, pixel_sha256, sha256

SPLITS = ("train", "validation", "test")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_rows(manifest):
    rows = read_json(manifest)["rows"]
    paths, groups, hashes = set(), {}, {}
    for row in rows:
        path = PurePosixPath(row["path"])
        label, split = row["label"], row["split"]
        if (
            label not in LABELS
            or split not in SPLITS
            or path.parts[:1] != (label,)
            or len(path.parts) != 2
            or ".." in path.parts
            or "\\" in row["path"]
            or row["path"] in paths
        ):
            raise ValueError(f"Fila inválida o duplicada: {row['path']}")
        paths.add(row["path"])
        for mapping, key in ((groups, row["group"]), (hashes, row["sha256"])):
            if mapping.setdefault(key, split) != split:
                raise ValueError("Grupo o imagen duplicada en varias particiones.")
    if {(r["split"], r["label"]) for r in rows} != {(s, c) for s in SPLITS for c in LABELS}:
        raise ValueError("Cada partición debe contener las tres clases.")
    return rows


def verify_pixels(rows, raw):
    for row in rows:
        with Image.open(raw / row["path"]) as image:
            if pixel_sha256(image) != row["sha256"]:
                raise ValueError(f"La imagen cambió después de la auditoría: {row['path']}")


def experiment_identity(model):
    return {"model_sha256": sha256(model), "splits_sha256": sha256(model.parent / "splits.json")}


def require_matching_report(path, identity, split):
    report = read_json(path)
    if report.get("identity") != identity or report.get("split") != split:
        raise ValueError(f"{path.name} no corresponde al modelo y a las particiones indicadas.")
    return report
