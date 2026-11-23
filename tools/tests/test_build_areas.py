import json

import numpy as np
import pytest

import build_areas as ba


def write_dem(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    xs, ys = np.arange(0, 201, 1.0) + 1000.0, np.arange(0, 151, 1.0) - 500.0
    lines = [f"{x} {y} {100.0 + 0.2 * (x - 1000.0)}" for y in ys for x in xs]
    path.write_text("\n".join(lines) + "\n")


def test_repository_manifest_is_valid():
    manifest = ba.load_manifest()
    assert len(manifest["areas"]) >= 2
    assert manifest["credit"] and manifest["license_url"].startswith("https://")


@pytest.mark.parametrize(
    "areas",
    [
        [],
        [{"tile": "A", "name": ""}],
        [{"tile": "", "name": "x"}],
        [{"tile": "A", "name": "x"}, {"tile": "A", "name": "y"}],
        [{"tile": "A", "name": "x"}, {"tile": "B", "name": "x"}],
    ],
)
def test_bad_manifest_is_rejected(tmp_path, areas):
    path = tmp_path / "areas.json"
    path.write_text(json.dumps({"credit": "c", "license_url": "https://x", "source": "s", "areas": areas}))
    with pytest.raises(ValueError):
        ba.load_manifest(path)


def test_build_writes_name_credit_bonfire_and_a_stable_id(tmp_path):
    manifest = {
        "credit": "出典",
        "license_url": "https://example.com/license",
        "source": "src",
        "areas": [{"tile": "08OF3006", "name": "寒天林道"}],
    }
    write_dem(tmp_path / "raw" / "src-08OF3006" / "08OF3006_DEM.txt")
    first = ba.build(tmp_path / "raw", tmp_path / "out", 1, manifest)[0]
    meta = json.loads(first.with_suffix(".json").read_text(encoding="utf-8"))
    assert meta["name"] == "寒天林道" and meta["credit"] == "出典"
    assert meta["world_id"].startswith("08OF3006-") and len(meta["bonfire"]) == 3
    again = ba.build(tmp_path / "raw", tmp_path / "out2", 2, manifest)[0]
    assert json.loads(again.with_suffix(".json").read_text(encoding="utf-8"))["world_id"] == meta["world_id"]
