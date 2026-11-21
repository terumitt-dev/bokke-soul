import numpy as np
import pytest

import dem_to_mesh as d2m
import pointcloud_to_mesh as p2m

# 平面直角座標のように、値が大きい座標にしておく
EAST0, NORTH0 = 42_400.25, -129_299.75


def write_dem(path, nx=20, ny=10, spacing=0.5, height=lambda e, n: 1000 + 0.1 * e + 0.2 * n):
    """東 北 標高 を 1 行ずつ書いた、等間隔のグリッド。北から南、西から東の順。"""
    rows = []
    for j in range(ny):
        for i in range(nx):
            e, n = i * spacing, j * spacing
            rows.append(f"{EAST0 + e:.3f} {NORTH0 + n:.3f} {height(e, n):.3f}")
    path.write_text("\n".join(rows) + "\n")
    return path


def test_load_dem_builds_a_grid(tmp_path):
    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt"))
    assert z.shape == (10, 20)
    assert xs[1] - xs[0] == pytest.approx(0.5)
    assert z[0, 0] == pytest.approx(1000.0)  # 南西の角
    assert z[9, 19] == pytest.approx(1000 + 0.1 * 9.5 + 0.2 * 4.5)  # 北東の角


def test_mesh_faces_point_up_after_conversion(tmp_path):
    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt"))
    mesh = d2m.convert(xs, ys, z)
    # 地形は上向きが表。Godot の Y 上向きで、全ての面が上を向く
    assert (mesh.face_normals[:, 1] > 0).all()
    assert len(mesh.faces) == (20 - 1) * (10 - 1) * 2


def test_mesh_is_centered_near_the_origin(tmp_path):
    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt"))
    mesh = d2m.convert(xs, ys, z)
    assert np.abs(mesh.bounds).max() < 100
    assert mesh.bounds[0] == pytest.approx([0, 0, -4.5], abs=1e-6)  # 北が -Z


def test_vertices_can_be_restored_to_survey_coordinates(tmp_path):
    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt"))
    mesh = d2m.convert(xs, ys, z)
    restored = p2m.from_godot_coords(mesh.vertices, mesh.metadata["origin"])
    assert restored[:, 0].min() == pytest.approx(EAST0)
    assert restored[:, 0].max() == pytest.approx(EAST0 + 9.5)
    assert restored[:, 1].min() == pytest.approx(NORTH0)
    assert restored[:, 2].min() == pytest.approx(1000.0)


def test_stride_makes_the_mesh_lighter(tmp_path):
    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt", nx=41, ny=21))
    full = d2m.convert(xs, ys, z, stride=1)
    light = d2m.convert(xs, ys, z, stride=2)
    assert len(light.faces) < len(full.faces) / 3
    assert light.metadata["spacing"] == pytest.approx(1.0)


def test_nodata_cells_have_no_faces(tmp_path):
    def height(e, n):
        return -9999.0 if 2.0 <= e <= 3.0 and 1.0 <= n <= 2.0 else 1000.0

    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt", height=height))
    assert np.isnan(z).any()
    mesh = d2m.convert(xs, ys, z)
    assert len(mesh.faces) < (20 - 1) * (10 - 1) * 2
    assert np.isfinite(mesh.vertices).all()


def test_not_a_grid_is_rejected(tmp_path):
    path = tmp_path / "dem.txt"
    path.write_text("1.0 1.0 10.0\n2.0 1.0 10.0\n3.0 1.0 10.0\n4.0 1.0 10.0\n")
    with pytest.raises(ValueError, match="格子になっていません"):
        d2m.load_dem(path)


def test_invalid_stride_is_rejected(tmp_path):
    xs, ys, z = d2m.load_dem(write_dem(tmp_path / "dem.txt"))
    with pytest.raises(ValueError, match="stride"):
        d2m.convert(xs, ys, z, stride=0)
