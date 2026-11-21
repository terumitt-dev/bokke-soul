import numpy as np
import pytest

import pointcloud_to_mesh as p2m


def synthetic_cloud(seed: int = 0) -> np.ndarray:
    """床 (20m x 20m) と壁 (x=10、高さ 3m) に、離れた場所のノイズ点を足した点群。"""
    rng = np.random.default_rng(seed)
    floor = np.column_stack([rng.uniform(0, 20, 40000), rng.uniform(0, 20, 40000), rng.normal(0, 0.01, 40000)])
    wall = np.column_stack([rng.normal(10, 0.01, 8000), rng.uniform(0, 20, 8000), rng.uniform(0, 3, 8000)])
    noise = rng.uniform([0, 0, 5], [20, 20, 8], (30, 3))  # 宙に浮いた点
    return np.concatenate([floor, wall, noise])


def test_single_voxel_is_a_closed_cube_with_outward_normals():
    grid = np.ones((1, 1, 1), dtype=bool)
    mesh = p2m.surface_mesh(grid, 1.0, np.zeros(3))
    assert len(mesh.faces) == 12
    assert mesh.is_watertight
    assert mesh.volume == pytest.approx(1.0)  # 内向きなら負になる


def test_internal_faces_are_not_emitted():
    grid = np.ones((2, 1, 1), dtype=bool)
    mesh = p2m.surface_mesh(grid, 1.0, np.zeros(3))
    assert len(mesh.faces) == 20  # 2 個の立方体 (24 面) から、接する 4 面を除く
    assert mesh.volume == pytest.approx(2.0)


def test_isolated_noise_is_removed():
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5, min_points=3, min_component=50)
    # Godot は Y が上。ノイズ (高さ 5〜8m) が残っていれば、高さがこの範囲を超える
    assert mesh.bounds[1][1] < 4.0


def test_floor_and_wall_are_kept():
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5)
    size = mesh.bounds[1] - mesh.bounds[0]
    assert size[0] == pytest.approx(20.0, abs=1.0)  # 床の幅
    assert size[1] > 2.5  # 壁の高さ
    assert len(mesh.faces) > 0


def test_axes_are_converted_to_y_up():
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5)
    assert mesh.is_winding_consistent
    top_faces = mesh.face_normals[:, 1] > 0.9
    assert top_faces.any()  # 床の上面が +Y を向く


def test_crop_limits_the_area():
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5, bounds=(0, 0, 5, 5))
    size = mesh.bounds[1] - mesh.bounds[0]
    assert size[0] <= 6.0


def test_empty_result_raises_a_clear_error():
    with pytest.raises(ValueError, match="切り出した範囲に点がありません"):
        p2m.convert(synthetic_cloud(), voxel_size=0.5, bounds=(100, 100, 110, 110))


def test_oversized_grid_is_rejected():
    points = np.array([[0.0, 0.0, 0.0], [10_000.0, 10_000.0, 10_000.0]])
    with pytest.raises(ValueError, match="格子が大きすぎます"):
        p2m.convert(points, voxel_size=0.5, min_points=1, min_component=1)


def test_unsupported_format_is_rejected(tmp_path):
    with pytest.raises(ValueError, match="未対応の形式"):
        p2m.load_points(tmp_path / "cloud.xyz")
