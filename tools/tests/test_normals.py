import json
import struct

import numpy as np
import pytest

import dem_to_mesh as d2m
import pointcloud_to_mesh as p2m
from sample_cloud import synthetic_cloud


def glb_json(path):
    """GLB の JSON 部分を読む (最初のチャンク)。"""
    data = path.read_bytes()
    length, kind = struct.unpack_from("<II", data, 12)
    assert kind == 0x4E4F534A  # "JSON"
    return json.loads(data[20 : 20 + length])


def primitive_attributes(path):
    meta = glb_json(path)
    return meta["meshes"][0]["primitives"][0]["attributes"]


def read_normals(path):
    """GLB から、頂点の法線を取り出す (trimesh は読み込み時に作り直すので、自分で読む)。"""
    meta = glb_json(path)
    data = path.read_bytes()
    json_length = struct.unpack_from("<I", data, 12)[0]
    binary_start = 20 + json_length + 8
    accessor = meta["accessors"][primitive_attributes(path)["NORMAL"]]
    view = meta["bufferViews"][accessor["bufferView"]]
    start = binary_start + view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    return np.frombuffer(data, dtype=np.float32, count=accessor["count"] * 3, offset=start).reshape(-1, 3)


def make_terrain():
    xs, ys = np.arange(0, 20) * 0.5, np.arange(0, 12) * 0.5
    # 東へ上る斜面 (傾き 0.5)
    z = np.tile(0.5 * xs, (len(ys), 1)) + 1000.0
    return d2m.convert(xs, ys, z)


def test_terrain_glb_has_normals(tmp_path):
    output = tmp_path / "terrain.glb"
    p2m.write_outputs(make_terrain(), output)
    assert "NORMAL" in primitive_attributes(output), "法線がないと、Godot は全ての面が同じ向きだと見なして、光が半分しか当たらない"


def test_terrain_normals_point_up_and_match_the_slope(tmp_path):
    output = tmp_path / "terrain.glb"
    p2m.write_outputs(make_terrain(), output)
    normals = read_normals(output)
    assert np.allclose(np.linalg.norm(normals, axis=1), 1.0, atol=1e-3)
    assert (normals[:, 1] > 0.5).all(), "地形の法線は、上 (Godot の +Y) を向く"
    # 東 (+X) へ上る斜面なので、法線は、西 (-X) へ傾く。傾きは atan(0.5) = 約 26.6 度
    mean = normals.mean(axis=0)
    mean /= np.linalg.norm(mean)
    assert mean[0] < -0.3, "東へ上る斜面の法線は、西へ傾く"
    assert abs(np.degrees(np.arccos(mean[1])) - np.degrees(np.arctan(0.5))) < 3.0, "法線の傾きが、斜面の傾きに合う"


def test_voxel_glb_has_flat_normals(tmp_path):
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5)
    output = tmp_path / "voxels.glb"
    p2m.write_outputs(mesh, output)
    assert "NORMAL" in primitive_attributes(output)
    normals = read_normals(output)
    # ボクセルは角ばった形なので、法線は、軸に沿った向きだけ (角で平均して丸めない)
    axis_aligned = (np.abs(normals).max(axis=1) > 0.999).mean()
    assert axis_aligned > 0.99, "ボクセルの面の法線は、軸に沿った向き (角ばって見える)"
    # 上向きの面 (床の上面) が、外向きの法線 (+Y) を持つ
    assert (normals[:, 1] > 0.99).any()


def test_normals_do_not_change_the_geometry(tmp_path):
    mesh = make_terrain()
    faces_before = len(mesh.faces)
    bounds_before = mesh.bounds.copy()
    p2m.write_outputs(mesh, tmp_path / "terrain.glb")
    assert len(mesh.faces) == faces_before
    assert np.allclose(mesh.bounds, bounds_before)
