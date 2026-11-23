import argparse
import json

import numpy as np
import pytest

import dem_to_mesh as d2m
import pointcloud_to_mesh as p2m


def terrain(plateau=(60.0, 40.0), edge_plateau=None):
    """斜面の中に、平らな場所 (plateau の東, 北。単位は m) がある、200 x 150 m の格子 (間隔 1 m)。"""
    xs, ys = np.arange(0, 201, 1.0), np.arange(0, 151, 1.0)
    gx, gy = np.meshgrid(xs, ys)
    z = 100.0 + 0.3 * gx + 0.2 * gy  # 全体が、斜面
    for e, n in [plateau] + ([edge_plateau] if edge_plateau else []):
        near = np.hypot(gx - e, gy - n) < 15
        if near.any():
            z[near] = z[near].mean()
    return xs, ys, z


def test_flat_spot_is_found_on_the_plateau():
    xs, ys, z = terrain()
    east, north, _, slope = d2m.find_flat_spot(xs, ys, z)
    assert np.hypot(east - 60.0, north - 40.0) < 10
    assert slope < 1.0  # 度。全体の斜面 (約 20 度) より、ずっと平ら


def test_spot_stays_away_from_the_edge():
    # 端の近くに、もっと平らな場所があっても、端 (出口になる) からは離す
    xs, ys, z = terrain(plateau=(100.0, 75.0), edge_plateau=(8.0, 75.0))
    east, north, _, _ = d2m.find_flat_spot(xs, ys, z, margin=40.0)
    assert 40.0 <= east <= 160.0 and 40.0 <= north <= 110.0


def test_spot_avoids_missing_elevation():
    xs, ys, z = terrain()
    z[30:50, 50:70] = np.nan  # 平らな場所に、標高の欠けがある
    east, north, elevation, _ = d2m.find_flat_spot(xs, ys, z)
    assert np.isfinite(elevation)
    window = z[int(north) - 6 : int(north) + 7, int(east) - 6 : int(east) + 7]
    assert np.isfinite(window).all()  # 選んだ場所の周りに、欠けがない


def test_explicit_bonfire_and_outside_are_checked():
    xs, ys, z = terrain()
    mesh = d2m.convert(xs, ys, z, bonfire=(120.0, 90.0))
    assert mesh.metadata["bonfire"][:2] == [120.0, 90.0]
    with pytest.raises(ValueError, match="マップの外"):
        d2m.convert(xs, ys, z, bonfire=(500.0, 90.0))
    z2 = z.copy()
    z2[90, 120] = np.nan
    with pytest.raises(ValueError, match="標高がありません"):
        d2m.convert(xs, ys, z2, bonfire=(120.0, 90.0))


def test_sidecar_has_bonfire_size_and_name(tmp_path):
    xs, ys, z = terrain()
    mesh = d2m.convert(xs, ys, z)
    p2m.apply_name(mesh, argparse.Namespace(name="  梨本  "))
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)
    meta = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
    assert meta["name"] == "梨本"
    assert len(meta["bonfire"]) == 3 and all(np.isfinite(meta["bonfire"]))
    # 篝火は、測量座標で持つ (作り直しても、原点が動いても、同じ場所を指す)
    east, north = meta["bonfire"][:2]
    assert xs[0] <= east <= xs[-1] and ys[0] <= north <= ys[-1]
    assert meta["size"][0] == pytest.approx(200.0) and meta["size"][2] == pytest.approx(150.0)  # GLB の幅 (東西) と奥行き (南北)


def test_no_name_means_no_key(tmp_path):
    xs, ys, z = terrain()
    mesh = d2m.convert(xs, ys, z)
    p2m.apply_name(mesh, argparse.Namespace(name=None))
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)
    assert "name" not in json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))


def test_same_bonfire_whatever_the_stride():
    # 間引きを変えても、篝火は、同じ場所 (間引く前の格子で決めるので、作り直しで動かない)
    xs, ys, z = terrain()
    places = {tuple(d2m.convert(xs, ys, z, stride=n).metadata["bonfire"]) for n in (1, 2, 3)}
    assert len(places) == 1


def test_manual_bonfire_writes_valid_json(tmp_path):
    # 手で決めた時、傾きは求めない。.json に NaN (正式な JSON ではない) が出ない
    xs, ys, z = terrain()
    mesh = d2m.convert(xs, ys, z, bonfire=(120.0, 90.0))
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)
    text = output.with_suffix(".json").read_text(encoding="utf-8")
    assert "NaN" not in text
    meta = json.loads(text, parse_constant=lambda name: pytest.fail(f"{name} が入っている"))
    assert "bonfire_slope_deg" not in meta and meta["bonfire"][:2] == [120.0, 90.0]


def test_no_place_for_a_bonfire_is_an_error():
    xs, ys, z = terrain()
    z[:] = np.nan  # 全面が欠け
    with pytest.raises(ValueError, match="置ける場所がありません"):
        d2m.find_flat_spot(xs, ys, z)


def test_ties_choose_the_center():
    # 全面が同じ傾きの平面なら、中央に近い所を選ぶ
    xs, ys = np.arange(0, 201, 1.0), np.arange(0, 151, 1.0)
    gx, gy = np.meshgrid(xs, ys)
    east, north, _, _ = d2m.find_flat_spot(xs, ys, 100.0 + 0.1 * gx)
    assert abs(east - 100.0) <= 2 and abs(north - 75.0) <= 2


def test_shrinking_the_margin_on_a_small_map_warns():
    xs, ys = np.arange(0, 101, 1.0), np.arange(0, 101, 1.0)
    gx, gy = np.meshgrid(xs, ys)
    with pytest.warns(UserWarning, match="縮めました"):
        d2m.find_flat_spot(xs, ys, 100.0 + 0.1 * gx, margin=40.0)


def test_grid_with_different_spacing_still_finds_a_place():
    # 東西 0.5 m、南北 10 m の間隔の格子 (load_dem が受け付ける形)。窓を東西の間隔だけで決めると、置ける場所がなくなる
    xs, ys = np.arange(0, 201, 0.5), np.arange(0, 151, 10.0)
    gx, gy = np.meshgrid(xs, ys)
    east, north, elevation, _ = d2m.find_flat_spot(xs, ys, 100.0 + 0.0 * gx)
    assert xs[0] <= east <= xs[-1] and ys[0] <= north <= ys[-1] and elevation == 100.0
