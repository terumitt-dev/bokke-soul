import json

import numpy as np
import pytest

import build_areas as ba
import dem_to_mesh as d2m

SPACING = 1.0


def make_grid(x0, y0, nx=40, ny=30, relief=False):
    """東西 nx、南北 ny 個の格子 (間隔 1 m)。標高は、位置の関数なので、隣のタイルとも、連続する。relief なら起伏がある。"""
    xs = x0 + np.arange(nx) * SPACING
    ys = y0 + np.arange(ny) * SPACING
    gx, gy = np.meshgrid(xs, ys)
    z = 100.0 + 0.1 * gx + 0.05 * gy
    if relief:
        z = z + 5.0 * np.sin(0.3 * gx) * np.cos(0.2 * gy)
    return xs, ys, z


def write_dem(root, source, tile, grid):
    xs, ys, z = grid
    path = root / f"{source}-{tile}" / f"{tile}_DEM.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"{x} {y} {z[j, i]}" for j, y in enumerate(ys) for i, x in enumerate(xs)) + "\n")


def layout(relief=False, diagonal=True):
    """中心 C と、東 E、北 N、北東 D (斜め) のタイル。格子は、隙間なく、つながっている。"""
    c = make_grid(0.0, 0.0, relief=relief)
    tiles = {
        "C": c,
        "E": make_grid(c[0][-1] + SPACING, 0.0, relief=relief),
        "N": make_grid(0.0, c[1][-1] + SPACING, relief=relief),
    }
    if diagonal:
        tiles["D"] = make_grid(c[0][-1] + SPACING, c[1][-1] + SPACING, relief=relief)
    return tiles


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


def manifest_for(tiles):
    return {
        "credit": "c",
        "license_url": "https://x",
        "source": "src",
        "areas": [{"tile": t, "name": f"area-{t}"} for t in tiles],
    }


def seam_vertices(sidecar_path, glb_path, east_of_origin=None, local_x=None):
    """GLB の頂点を、測量座標 (東, 北, 標高) に直して返す。"""
    import trimesh

    meta = json.loads(sidecar_path.read_text(encoding="utf-8"))
    vertices = np.asarray(trimesh.load(glb_path, force="mesh").vertices, dtype=float)
    origin = np.array(meta["origin"])
    return np.column_stack([vertices[:, 0] + origin[0], -vertices[:, 2] + origin[1], vertices[:, 1] + origin[2]])


@pytest.mark.parametrize("stride", [2, 3])
def test_seam_vertices_match_even_when_row_counts_differ(tmp_path, stride):
    # 起伏のある標高で、継ぎ目の上の頂点が、両側で、同じ位置・同じ標高になること (T 字の継ぎ目の隙間が、できない)。
    # C は北の隣があって行が 1 つ多く、E には北の隣がない (行数が違う)
    root = tmp_path / "raw"
    grids = layout(relief=True, diagonal=False)
    for tile, grid in grids.items():
        write_dem(root, "src", tile, grid)
    outputs = ba.build(root, tmp_path / "out", stride, manifest_for(grids))
    by_name = {o.stem: o for o in outputs}
    seam_e = grids["E"][0][0]
    on_seam = {}
    for tile in ("C", "E"):
        vertices = seam_vertices(by_name[tile].with_suffix(".json"), by_name[tile])
        on_seam[tile] = vertices[np.isclose(vertices[:, 0], seam_e, atol=1e-6)]
    # E の北の端 (最後の行) は、C の格子の線に乗らないことがある (C は、その先まで続く)。そこだけは、継ぎ目の端なので、比べない
    top = grids["E"][1][-1]
    c = {round(n, 6): e for _, n, e in on_seam["C"] if n < top - 1e-9}
    e = {round(n, 6): h for _, n, h in on_seam["E"] if n < top - 1e-9}
    assert set(c) == set(e), f"継ぎ目の頂点の位置が、食い違う: C だけ {sorted(set(c) - set(e))}、E だけ {sorted(set(e) - set(c))}"
    assert all(abs(c[n] - e[n]) < 1e-6 for n in c)  # 標高も同じ


def test_bonfire_does_not_move_when_neighbours_are_added(tmp_path):
    root = tmp_path / "raw"
    grids = layout(relief=True)
    for tile, grid in grids.items():
        write_dem(root, "src", tile, grid)
    alone = ba.build(root, tmp_path / "a", 2, manifest_for(["C"]))[0]
    together = ba.build(root, tmp_path / "b", 2, manifest_for(grids))[0]
    a = json.loads(alone.with_suffix(".json").read_text(encoding="utf-8"))
    b = json.loads(together.with_suffix(".json").read_text(encoding="utf-8"))
    assert a["bonfire"] == b["bonfire"] and a["bonfire_slope_deg"] == b["bonfire_slope_deg"]


def test_only_one_neighbour_is_added():
    c = make_grid(0.0, 0.0)
    east_only = ba.stitch({"C": c, "E": make_grid(c[0][-1] + SPACING, 0.0)})["C"]
    assert len(east_only[0]) == len(c[0]) + 1 and len(east_only[1]) == len(c[1])
    north_only = ba.stitch({"C": c, "N": make_grid(0.0, c[1][-1] + SPACING)})["C"]
    assert len(north_only[1]) == len(c[1]) + 1 and len(north_only[0]) == len(c[0])


def test_large_survey_coordinates_use_absolute_tolerance():
    # 測量座標の値が大きいと、相対の許容誤差が、0.5 m のずれを、許してしまう。距離 (m) だけで見る
    c = make_grid(42400.25, -129299.75)
    shifted = make_grid(c[0][-1] + SPACING, -129299.75 + 0.5)  # 南北が 0.5 m ずれている
    assert ba.stitch({"C": c, "X": shifted})["C"][2].shape == c[2].shape
    aligned = make_grid(c[0][-1] + SPACING, -129299.75)
    assert ba.stitch({"C": c, "X": aligned})["C"][2].shape[1] == c[2].shape[1] + 1


def test_unusual_neighbours():
    c = make_grid(0.0, 0.0)
    coarse = (c[0][-1] + 2.0 + np.arange(40) * 2.0, c[1], np.zeros((30, 40)))  # 間隔が違う
    assert ba.stitch({"C": c, "X": coarse})["C"][2].shape == c[2].shape
    single = (np.array([c[0][-1] + SPACING]), c[1], np.zeros((30, 1)))  # 1 列だけ (間隔が分からない)
    assert ba.stitch({"C": c, "X": single})["C"][2].shape == c[2].shape  # 落ちずに、足さない
    twin_a = make_grid(c[0][-1] + SPACING, 0.0)
    twin_b = make_grid(c[0][-1] + SPACING, 0.0)
    with pytest.raises(ValueError, match="2 つ以上"):
        ba.stitch({"C": c, "A": twin_a, "B": twin_b})


def test_sampling_uses_one_lattice_across_tiles():
    # 全体の格子の線に合わせて間引く。2 つのタイルの、継ぎ目の両側が、同じ番号の線を使う
    left = d2m.sample_indices(10, 3, 0)  # 全体の 0〜9 番
    right = d2m.sample_indices(10, 3, 9)  # 全体の 9〜18 番 (9 番は、継ぎ目で、共有)
    assert set(left + 0) & set(right + 9) == {9}
    assert all((i + 9) % 3 == 0 or i in (0, 9) for i in right)
