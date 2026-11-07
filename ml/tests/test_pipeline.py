import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from common import LABELS, load_image, resize_rgb
from prepare_data import audit, leaf_id, split_rows


def test_resize_contract():
    source = np.array([[[0, 0, 0], [100, 100, 100]], [[200, 200, 200], [240, 240, 240]]], dtype=np.uint8)
    assert np.allclose(resize_rgb(source, 1), [[[135, 135, 135]]])
    assert resize_rgb(source).dtype == np.float32


def test_exif_orientation_and_rgb(tmp_path):
    im = Image.new("RGB", (4, 2), (255, 0, 0))
    exif = im.getexif()
    exif[274] = 6
    path = tmp_path / "test.jpg"
    im.save(path, exif=exif)
    image = load_image(path)
    assert image.shape == (224, 224, 3)
    assert image[:, :, 0].mean() > 250


def test_group_disjoint_and_reproducible():
    rows = [dict(label=c, group=f"{c}-{i // 2}", path=f"{c}/{i}.jpg") for c in LABELS for i in range(40)]
    a = split_rows(rows)
    assert a == split_rows(rows)
    groups = {}
    for r in a:
        groups.setdefault(r["group"], set()).add(r["split"])
    assert all(len(s) == 1 for s in groups.values())
    assert all(
        any(r["label"] == c and r["split"] == s for r in a) for c in LABELS for s in ["train", "validation", "test"]
    )


def test_leaf_variants():
    assert leaf_id("uuid___GH_HL Leaf 308.1.JPG") == leaf_id("other___GH_HL Leaf 308.2.JPG")


def test_corrupt_and_conflicting_labels(tmp_path):
    for c in LABELS:
        (tmp_path / c).mkdir()
    Image.new("RGB", (16, 16), "red").save(tmp_path / LABELS[0] / "a.png")
    Image.new("RGB", (16, 16), "red").save(tmp_path / LABELS[1] / "b.png")
    (tmp_path / LABELS[2] / "broken.jpg").write_bytes(b"not an image")
    _, report = audit(tmp_path)
    assert report["unreadable"]
    assert report["label_conflicts"]


def test_numpy_history_json(tmp_path):
    import json
    from common import write_json

    path = tmp_path / "history.json"
    write_json(path, {"lr": [np.float32(0.001)], "scores": np.array([0.1, 0.9])})
    assert abs(json.loads(path.read_text())["lr"][0] - 0.001) < 1e-8


def test_manifest_and_pixel_tampering(tmp_path):
    import pytest

    from common import pixel_sha256, write_json
    from experiment import load_rows, verify_pixels

    path = tmp_path / LABELS[0] / "leaf.png"
    path.parent.mkdir()
    image = Image.new("RGB", (8, 8), "red")
    image.save(path)
    rows = [
        dict(path=f"{label}/{split}.png", label=label, split=split, group=f"{label}-{split}", sha256=f"{label}-{split}")
        for label in LABELS
        for split in ("train", "validation", "test")
    ]
    rows[0].update(path=f"{LABELS[0]}/leaf.png", sha256=pixel_sha256(image))
    manifest = tmp_path / "splits.json"
    write_json(manifest, {"rows": rows})
    assert len(load_rows(manifest)) == 9
    verify_pixels(rows[:1], tmp_path)
    Image.new("RGB", (8, 8), "blue").save(path)
    with pytest.raises(ValueError, match="cambió"):
        verify_pixels(rows[:1], tmp_path)
    rows[1]["sha256"] = rows[0]["sha256"]
    write_json(manifest, {"rows": rows})
    with pytest.raises(ValueError, match="varias particiones"):
        load_rows(manifest)


def test_decision_threshold_balances_coverage_and_accuracy():
    from decision import acceptance_summary, choose_threshold

    scores = [0.99, 0.91, 0.85, 0.7]
    correct = [True, True, False, False]
    chosen = choose_threshold(scores, correct, min_accuracy=0.9, min_coverage=0.5)
    assert chosen["min_score"] == 0.91
    assert chosen["coverage"] == 0.5
    assert acceptance_summary(scores, correct, 0.85)["correct_accepted"] == 2
    assert choose_threshold(scores, correct, min_accuracy=0.9, min_coverage=0.75) is None


def test_evaluation_cannot_be_reused_for_different_weights(tmp_path):
    import pytest

    from common import write_json
    from experiment import experiment_identity, require_matching_report

    model = tmp_path / "model.keras"
    model.write_bytes(b"first")
    (tmp_path / "splits.json").write_bytes(b"fixed split")
    identity = experiment_identity(model)
    report = tmp_path / "evaluation.json"
    write_json(report, {"identity": identity, "split": "test", "test_images": 9})
    assert require_matching_report(report, identity, "test")["test_images"] == 9
    model.write_bytes(b"replacement")
    with pytest.raises(ValueError, match="no corresponde"):
        require_matching_report(report, experiment_identity(model), "test")
