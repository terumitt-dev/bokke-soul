import json

import numpy as np
import pytest

import build_areas as ba
import dem_to_mesh as d2m

SPACING = 1.0


def make_grid(x0, y0, nx=40, ny=30):
    """東西 nx、南北 ny 個の格子 (間隔 1 m)。標高は、位置の関数なので、隣のタイルとも、連続する。"""
    xs = x0 + np.arange(nx) * SPACING
    ys = y0 + np.arange(ny) * SPACING
    gx, gy = np.meshgrid(xs, ys)
    return xs, ys, 100.0 + 0.1 * gx + 0.05 * gy


def write_dem(root, source, tile, grid):
    xs, ys, z = grid
    path = root / f"{source}-{tile}" / f"{tile}_DEM.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"{x} {y} {z[j, i]}" for j, y in enumerate(ys) for i, x in enumerate(xs)) + "\n")


def layout():
    """中心 C と、東 E、北 N、北東 D (斜め) のタイル。格子は、隙間なく、つながっている。"""
    c = make_grid(0.0, 0.0)
    return {
        "C": c,
        "E": make_grid(c[0][-1] + SPACING, 0.0),
        "N": make_grid(0.0, c[1][-1] + SPACING),
        "D": make_grid(c[0][-1] + SPACING, c[1][-1] + SPACING),
    }


def test_east_and_north_neighbours_are_appended():
    grids = layout()
    out = ba.stitch(grids)
    xs, ys, z = out["C"]
    assert len(xs) == len(grids["C"][0]) + 1 and len(ys) == len(grids["C"][1]) + 1
    assert xs[-1] == grids["E"][0][0] and ys[-1] == grids["N"][1][0]  # 隣の最初の列・行まで伸びる
    assert np.array_equal(z[:-1, -1], grids["E"][2][:, 0])  # 東の隣の最初の列の標高
    assert np.array_equal(z[-1, :-1], grids["N"][2][0, :])  # 北の隣の最初の行の標高


def test_corner_uses_the_diagonal_tile_or_is_missing():
    grids = layout()
    assert ba.stitch(grids)["C"][2][-1, -1] == grids["D"][2][0, 0]
    without = {k: v for k, v in grids.items() if k != "D"}
    assert np.isnan(ba.stitch(without)["C"][2][-1, -1])  # 斜めがなければ、欠け (その 1 マスだけ、面を作らない)


def test_tiles_without_neighbours_are_unchanged():
    grids = layout()
    out = ba.stitch(grids)
    assert out["D"][0].shape == grids["D"][0].shape and out["D"][2].shape == grids["D"][2].shape  # 北東の端のタイルには、隣がない


def test_gap_or_misaligned_tiles_are_not_stitched():
    c = make_grid(0.0, 0.0)
    far = make_grid(c[0][-1] + 5.0, 0.0)  # 隙間がある
    shifted = make_grid(c[0][-1] + SPACING, 0.5)  # 行が、ずれている
    for other in (far, shifted):
        out = ba.stitch({"C": c, "X": other})
        assert out["C"][2].shape == c[2].shape


@pytest.mark.parametrize("count,stride,expected_last", [(800, 2, 799), (801, 2, 800), (10, 3, 9), (2, 5, 1)])
def test_sampling_always_keeps_the_last(count, stride, expected_last):
    indices = d2m.sample_indices(count, stride)
    assert indices[0] == 0 and indices[-1] == expected_last and np.all(np.diff(indices) > 0)


@pytest.mark.parametrize("stride", [1, 2, 3])
def test_built_meshes_meet_exactly_at_the_seams(tmp_path, stride):
    root = tmp_path / "raw"
    grids = layout()
    for tile, grid in grids.items():
        write_dem(root, "src", tile, grid)
    manifest = {
        "credit": "出典",
        "license_url": "https://example.com/license",
        "source": "src",
        "areas": [{"tile": tile, "name": f"area-{tile}"} for tile in grids],
    }
    outputs = ba.build(root, tmp_path / "out", stride, manifest)
    meta = {o.stem: json.loads(o.with_suffix(".json").read_text(encoding="utf-8")) for o in outputs}

    def east_edge(tile):
        return meta[tile]["origin"][0] + meta[tile]["size"][0]

    def north_edge(tile):
        return meta[tile]["origin"][1] + meta[tile]["size"][2]  # GLB の奥行き = 南北

    assert east_edge("C") == pytest.approx(meta["E"]["origin"][0], abs=1e-9)  # 東の隣と、端がそろう (隙間がない)
    assert north_edge("C") == pytest.approx(meta["N"]["origin"][1], abs=1e-9)
    assert east_edge("N") == pytest.approx(meta["D"]["origin"][0], abs=1e-9)
    assert north_edge("E") == pytest.approx(meta["D"]["origin"][1], abs=1e-9)


def test_world_id_does_not_change_by_stitching(tmp_path):
    # 世界の名前は、継ぎ目を足す前の、元のタイルの角から決まる。隣のタイルが増えても、変わらない
    root = tmp_path / "raw"
    grids = layout()
    for tile, grid in grids.items():
        write_dem(root, "src", tile, grid)
    base = {"credit": "c", "license_url": "https://x", "source": "src"}
    alone = ba.build(root, tmp_path / "a", 2, {**base, "areas": [{"tile": "C", "name": "c"}]})[0]
    together = ba.build(root, tmp_path / "b", 2, {**base, "areas": [{"tile": t, "name": t} for t in grids]})[0]
    assert json.loads(alone.with_suffix(".json").read_text(encoding="utf-8"))["world_id"] == json.loads(together.with_suffix(".json").read_text(encoding="utf-8"))["world_id"]
