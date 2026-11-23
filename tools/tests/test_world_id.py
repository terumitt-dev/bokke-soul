import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
import trimesh

import dem_to_mesh as d2m
import pointcloud_to_mesh as p2m


def make_mesh(offset=0.0):
    xs, ys = np.arange(0, 5) * 0.5 + offset, np.arange(0, 4) * 0.5
    return d2m.convert(xs, ys, np.full((4, 5), 100.0))


TOOLS = Path(__file__).resolve().parent.parent


def run_tool(script, *arguments):
    subprocess.run([sys.executable, str(TOOLS / script), *map(str, arguments)], check=True, capture_output=True)


def args(**kwargs):
    return argparse.Namespace(**{"world_id": None, **kwargs})


def test_id_uses_tile_number_and_anchor():
    world_id = p2m.derive_world_id(Path("2019-LP-Grid-08OF3006_DEM.txt"), np.array([10.0, 20.0]))
    assert world_id.startswith("08OF3006-")
    assert p2m.WORLD_ID_PATTERN.fullmatch(world_id)


def test_dem_stride_does_not_change_the_id(tmp_path):
    # 間引きの細かさを変えても、同じ入力なら同じ名前。周囲の標高が高く、角だけ低いと、
    # 間引きで原点の標高が動くが、名前は水平の角で決まるので、変わらない
    path = tmp_path / "08OF3006_DEM.txt"
    lines = [f"{e} {n} {0.0 if (e, n) == (101, 201) else 100.0}" for n in range(200, 206) for e in range(100, 106)]
    path.write_text("\n".join(lines) + "\n")
    ids = set()
    for stride in (1, 2):
        out = tmp_path / f"w{stride}.glb"
        run_tool("dem_to_mesh.py", path, out, "--stride", str(stride))
        ids.add(json.loads(out.with_suffix(".json").read_text(encoding="utf-8"))["world_id"])
    assert len(ids) == 1


def test_crop_does_not_change_the_id(tmp_path):
    # 切り出しの範囲を変えると、メッシュの原点は動くが、名前は変わらない
    rng = np.random.default_rng(0)
    xy = rng.uniform(0, 20, size=(4000, 2))
    points = np.column_stack([xy, 0.1 * rng.random(4000)])
    path = tmp_path / "08OF3006.ply"
    trimesh.PointCloud(points).export(path)
    metas = []
    for crop in (["0", "0", "20", "20"], ["8", "8", "20", "20"]):
        out = tmp_path / f"w{crop[0]}.glb"
        run_tool("pointcloud_to_mesh.py", path, out, "--voxel", "1", "--min-points", "1", "--min-component", "1", "--crop", *crop)
        metas.append(json.loads(out.with_suffix(".json").read_text(encoding="utf-8")))
    assert metas[0]["origin"] != metas[1]["origin"]  # 原点は動く (この確認が、テストの前提)
    assert metas[0]["world_id"] == metas[1]["world_id"]


def test_different_place_gets_another_id():
    source = Path("08OF3006.txt")
    assert p2m.derive_world_id(source, np.array([0.0, 0.0])) != p2m.derive_world_id(source, np.array([1000.0, 0.0]))


def test_name_without_tile_number_is_made_safe():
    world_id = p2m.derive_world_id(Path("my scan (v2).ply"), np.array([0.0, 0.0]))
    assert p2m.WORLD_ID_PATTERN.fullmatch(world_id)


def test_explicit_id_wins_and_is_written_to_the_sidecar(tmp_path):
    mesh = make_mesh()
    p2m.apply_world_id(mesh, args(world_id="kagoshima-sakurajima"), Path("x.ply"), np.array([0.0, 0.0]))
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)
    meta = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
    assert meta["world_id"] == "kagoshima-sakurajima"


@pytest.mark.parametrize("bad", ["../etc", ".hidden", "..", "a/b", "名前", "", "x" * 65, "abc\n"])
def test_unsafe_id_is_rejected(bad):
    # セーブのファイル名に使うので、パスや日本語は通さない。空は「省略」と同じ扱い
    mesh = make_mesh()
    if bad == "":
        p2m.apply_world_id(mesh, args(world_id=bad), Path("08OF3006.txt"), np.array([0.0, 0.0]))
        assert mesh.metadata["world_id"].startswith("08OF3006-")
    else:
        with pytest.raises(ValueError, match="世界の名前"):
            p2m.apply_world_id(mesh, args(world_id=bad), Path("x.ply"), np.array([0.0, 0.0]))
