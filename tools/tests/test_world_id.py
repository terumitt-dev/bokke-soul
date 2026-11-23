import argparse
import json
from pathlib import Path

import numpy as np
import pytest

import dem_to_mesh as d2m
import pointcloud_to_mesh as p2m


def make_mesh(offset=0.0):
    xs, ys = np.arange(0, 5) * 0.5 + offset, np.arange(0, 4) * 0.5
    return d2m.convert(xs, ys, np.full((4, 5), 100.0))


def args(**kwargs):
    return argparse.Namespace(**{"world_id": None, **kwargs})


def test_id_uses_tile_number_and_origin():
    world_id = p2m.derive_world_id(Path("2019-LP-Grid-08OF3006_DEM.txt"), np.array([10.0, 20.0, 5.0]))
    assert world_id.startswith("08OF3006-")
    assert p2m.WORLD_ID_PATTERN.fullmatch(world_id)


def test_same_place_keeps_the_id_whatever_the_mesh_detail():
    # 細かさ (stride) や、範囲の広がりを変えても、原点が同じなら名前は変わらない
    xs, ys = np.arange(0, 9) * 0.5, np.arange(0, 9) * 0.5
    fine = d2m.convert(xs, ys, np.full((9, 9), 100.0), stride=1)
    coarse = d2m.convert(xs, ys, np.full((9, 9), 100.0), stride=2)
    source = Path("08OF3006.txt")
    assert p2m.derive_world_id(source, fine.metadata["origin"]) == p2m.derive_world_id(source, coarse.metadata["origin"])


def test_different_place_gets_another_id():
    source = Path("08OF3006.txt")
    assert p2m.derive_world_id(source, make_mesh().metadata["origin"]) != p2m.derive_world_id(
        source, make_mesh(offset=1000.0).metadata["origin"]
    )


def test_name_without_tile_number_is_made_safe():
    world_id = p2m.derive_world_id(Path("my scan (v2).ply"), np.array([0.0, 0.0, 0.0]))
    assert p2m.WORLD_ID_PATTERN.fullmatch(world_id)


def test_explicit_id_wins_and_is_written_to_the_sidecar(tmp_path):
    mesh = make_mesh()
    p2m.apply_world_id(mesh, args(world_id="kagoshima-sakurajima"), Path("x.ply"))
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)
    meta = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
    assert meta["world_id"] == "kagoshima-sakurajima"


@pytest.mark.parametrize("bad", ["../etc", ".hidden", "..", "a/b", "名前", "", "x" * 65])
def test_unsafe_id_is_rejected(bad):
    # セーブのファイル名に使うので、パスや日本語は通さない。空は「省略」と同じ扱い
    mesh = make_mesh()
    if bad == "":
        p2m.apply_world_id(mesh, args(world_id=bad), Path("08OF3006.txt"))
        assert mesh.metadata["world_id"].startswith("08OF3006-")
    else:
        with pytest.raises(ValueError, match="世界の名前"):
            p2m.apply_world_id(mesh, args(world_id=bad), Path("x.ply"))
