import numpy as np
import pytest

import pointcloud_to_mesh as p2m
from sample_cloud import synthetic_cloud


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
    # 最も高い位置にある面 (床の上面や壁の天面) は、全て +Y を向く
    top = np.isclose(mesh.triangles_center[:, 1], mesh.bounds[1][1])
    assert top.any()
    assert (mesh.face_normals[top, 1] > 0.99).all()


def test_converted_mesh_is_outward_facing():
    # 変換後の法線が内向きだと、背面カリングで床が見えず、当たり判定も片面になる
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5)
    assert mesh.volume > 0


def test_converted_single_voxel_is_closed_and_outward():
    points = np.random.default_rng(0).uniform(0, 1, (200, 3))
    mesh = p2m.convert(points, voxel_size=1.0, min_points=1, min_component=1)
    assert mesh.is_watertight
    assert mesh.volume == pytest.approx(1.0)


def test_mesh_is_centered_near_the_origin():
    # 平面直角座標のように値が大きい点群でも、float32 の精度が落ちない位置に出力する
    points = synthetic_cloud() + np.array([-35_000.0, 3_000.0, 40.0])
    mesh = p2m.convert(points, voxel_size=0.5)
    assert np.abs(mesh.bounds).max() < 100
    assert mesh.metadata["origin"] == pytest.approx(points.min(axis=0))


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


def test_vertices_can_be_restored_to_survey_coordinates():
    points = synthetic_cloud() + np.array([-35_000.0, 3_000.0, 40.0])
    mesh = p2m.convert(points, voxel_size=0.5)
    restored = p2m.from_godot_coords(mesh.vertices, mesh.metadata["origin"])
    # 元の点群の範囲に、ボクセル 1 つ分の余裕を足した中に収まる (軸が混ざると外れる)
    low, high = points.min(axis=0) - 0.5, points.max(axis=0) + 0.5
    assert (restored.min(axis=0) >= low).all()
    assert (restored.max(axis=0) <= high).all()
    # 床の高さ (z) と壁の位置 (x) も、元の軸のまま
    assert restored[:, 2].min() == pytest.approx(points[:, 2].min(), abs=0.5)
    assert restored[:, 0].max() == pytest.approx(points[:, 0].max(), abs=1.0)
