"""Audit data and persist group-disjoint splits BEFORE batching/augmentation."""

import argparse
import json
import random
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

from common import LABELS, ROOT, pixel_sha256, write_json


class UnionFind:
    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, n):
        while n != self.parent[n]:
            self.parent[n] = self.parent[self.parent[n]]
            n = self.parent[n]
        return n

    def join(self, a, b):
        self.parent[self.find(a)] = self.find(b)


def leaf_id(name):
    # GH_HL Leaf 308.1 and 308.2 belong to the same leaf; also RS_* acquisition IDs.
    m = re.search(r"___(.+?)\s+(?:Leaf\s+)?(\d+)", name, re.I)
    return f"{m[1].lower()}:{m[2]}" if m else None


def audit(raw, near_distance=2):
    rows, bad = [], []
    for label in LABELS:
        folder = raw / label
        if not folder.is_dir():
            raise ValueError(f"Falta carpeta: {folder}")
        for p in sorted(folder.iterdir()):
            if not p.is_file() or p.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
                continue
            try:
                with Image.open(p) as im:
                    im.load()
                    rgb = ImageOps.exif_transpose(im).convert("RGB")
                    digest = pixel_sha256(rgb)
                    small = np.asarray(rgb.convert("L").resize((9, 8)))
                    dhash = sum(int(v) << j for j, v in enumerate((small[:, 1:] > small[:, :-1]).flat))
                    rows.append(
                        dict(
                            path=p.relative_to(raw).as_posix(),
                            label=label,
                            sha256=digest,
                            dhash=dhash,
                            width=rgb.width,
                            height=rgb.height,
                            leaf_id=leaf_id(p.name),
                        )
                    )
            except Exception as e:
                bad.append(dict(path=str(p), error=str(e)))
    uf = UnionFind(len(rows))
    hashes, leaves, near_pairs, conflicts = {}, {}, [], []
    for n, row in enumerate(rows):
        if row["sha256"] in hashes:
            other = hashes[row["sha256"]]
            uf.join(n, other)
            if rows[other]["label"] != row["label"]:
                conflicts.append([rows[other]["path"], row["path"]])
        hashes[row["sha256"]] = n
        if row["leaf_id"]:
            key = (row["label"], row["leaf_id"])
            if key in leaves:
                uf.join(n, leaves[key])
            leaves[key] = n
    for n, row in enumerate(rows):
        for j in range(n):
            if (row["dhash"] ^ rows[j]["dhash"]).bit_count() <= near_distance:
                near_pairs.append([rows[j]["path"], row["path"]])
                if row["label"] == rows[j]["label"]:
                    uf.join(n, j)
                else:
                    conflicts.append([rows[j]["path"], row["path"]])
    for n, row in enumerate(rows):
        row["group"] = str(uf.find(n))
    return rows, dict(
        unreadable=bad,
        duplicate_count=len(rows) - len(hashes),
        similar_pairs=near_pairs,
        label_conflicts=conflicts,
        near_distance=near_distance,
    )


def split_rows(rows, seed=42):
    rng = random.Random(seed)
    result = []
    for label in LABELS:
        groups = {}
        for row in rows:
            if row["label"] == label:
                groups.setdefault(row["group"], []).append(row)
        items = list(groups.values())
        if len(items) < 3:
            raise ValueError(f"{label}: se necesitan al menos tres grupos independientes.")
        rng.shuffle(items)
        items.sort(key=len, reverse=True)
        total = sum(map(len, items))
        targets = dict(train=0.7 * total, validation=0.15 * total, test=0.15 * total)
        counts = dict.fromkeys(targets, 0)
        for group in items:
            # Relative deficit balances large groups without splitting a leaf/duplicate.
            subset = max(targets, key=lambda s: (targets[s] - counts[s]) / targets[s])
            counts[subset] += len(group)
            result.extend(dict(r, split=subset) for r in group)
        if any(v == 0 for v in counts.values()):
            raise ValueError(f"No se puede separar {label}; revisa grupos similares.")
    return result


def prepare(raw, out, seed=42, near_distance=2):
    rows, report = audit(raw, near_distance)
    write_json(out / "data_audit.json", report)
    if report["unreadable"] or report["label_conflicts"]:
        raise ValueError(
            f"Revisa {out / 'data_audit.json'}: archivos dañados o etiquetas conflictivas. No se modificó raw."
        )
    rows = split_rows(rows, seed)
    report["counts"] = {
        split: {label: sum(r["split"] == split and r["label"] == label for r in rows) for label in LABELS}
        for split in ("train", "validation", "test")
    }
    write_json(out / "data_audit.json", report)
    manifest = dict(
        seed=seed,
        raw_path=str(raw),
        rows=rows,
        caveat="Agrupación por ID disponible, píxeles y dHash; revisar similitud manualmente. No garantiza identificar todas las hojas relacionadas.",
    )
    write_json(out / "splits.json", manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=ROOT / "ml/data/raw")
    parser.add_argument("--output", type=Path, default=ROOT / "ml/data/processed")
    parser.add_argument("--near-distance", type=int, default=2)
    args = parser.parse_args()
    if (args.output / "splits.json").exists():
        raise SystemExit(
            "Ya existe splits.json: consérvalo para comparar experimentos. Usa otro --output para un dataset distinto."
        )
    m = prepare(args.data.resolve(), args.output, near_distance=args.near_distance)
    print(
        json.dumps(
            {
                s: {c: sum(r["split"] == s and r["label"] == c for r in m["rows"]) for c in LABELS}
                for s in ["train", "validation", "test"]
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
