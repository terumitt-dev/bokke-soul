"""標高グリッド (テキスト) を、Godot で歩ける地形メッシュ (GLB) に変換する。

入力は 1 行に「東 北 標高」を並べた等間隔のグリッド (VIRTUAL SHIZUOKA の Grid の _DEM.txt など)。
点群を一度ボクセルにする pointcloud_to_mesh.py と違い、格子のまま 2 枚の三角形にするので、
地形が滑らかで、面の数も少ない。

使い方:
    python tools/dem_to_mesh.py data/raw/xxx_DEM.txt data/processed/terrain.glb --stride 2
"""

import argparse
from pathlib import Path

import numpy as np
import trimesh

from pointcloud_to_mesh import to_godot_axes, write_outputs

# これ以下の標高は「データなし」として扱う
NODATA_BELOW = -9000.0


def load_dem(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(東の座標, 北の座標, 標高の 2 次元配列 [北, 東]) を返す。格子に欠けがあれば NaN を入れる。"""
    data = np.loadtxt(path, usecols=(0, 1, 2), dtype=np.float64, ndmin=2)
    if data.shape[0] < 4:
        raise ValueError("点が少なすぎます")
    xs = np.unique(data[:, 0])
    ys = np.unique(data[:, 1])
    if len(xs) < 2 or len(ys) < 2:
        raise ValueError("格子になっていません (東西・南北にそれぞれ 2 点以上が必要です)")
    for name, axis in (("東西", xs), ("南北", ys)):
        steps = np.diff(axis)
        if not np.allclose(steps, steps[0], rtol=1e-3):
            raise ValueError(f"{name}が等間隔の格子ではありません (行や列が欠けている可能性があります)")
    z = np.full((len(ys), len(xs)), np.nan)
    z[np.searchsorted(ys, data[:, 1]), np.searchsorted(xs, data[:, 0])] = data[:, 2]
    z[z <= NODATA_BELOW] = np.nan
    return xs, ys, z


def heightfield_mesh(xs: np.ndarray, ys: np.ndarray, z: np.ndarray) -> trimesh.Trimesh:
    """格子を 2 枚ずつの三角形にする。標高が欠けた格子は面を作らない。上向き (+Z) が表。"""
    ny, nx = z.shape
    gx, gy = np.meshgrid(xs, ys)
    vertices = np.column_stack([gx.ravel(), gy.ravel(), z.ravel()])

    index = np.arange(ny * nx).reshape(ny, nx)
    # 行は北へ、列は東へ進む。a が南西、b が南東、c が北東、d が北西の角
    a, b = index[:-1, :-1], index[:-1, 1:]
    d, c = index[1:, :-1], index[1:, 1:]
    valid = np.isfinite(z[:-1, :-1]) & np.isfinite(z[:-1, 1:]) & np.isfinite(z[1:, :-1]) & np.isfinite(z[1:, 1:])
    a, b, c, d = a[valid], b[valid], c[valid], d[valid]
    # (a, b, c)、(a, c, d) は、真上から見て反時計回り。法線は +Z を向く
    faces = np.concatenate([np.column_stack([a, b, c]), np.column_stack([a, c, d])])
    if len(faces) == 0:
        raise ValueError("標高のある格子がありません")

    mesh = trimesh.Trimesh(vertices=vertices, faces=faces, process=False)
    mesh.remove_unreferenced_vertices()
    return mesh


def convert(xs: np.ndarray, ys: np.ndarray, z: np.ndarray, stride: int = 1) -> trimesh.Trimesh:
    """格子を stride 個おきに間引いて地形メッシュにし、原点付近へ寄せて Godot の軸にする。"""
    if stride < 1:
        raise ValueError("stride は 1 以上にしてください")
    xs, ys, z = xs[::stride], ys[::stride], z[::stride, ::stride]
    mesh = heightfield_mesh(xs, ys, z)
    # 測量の座標は値が大きいので、float32 の精度落ちを避けて、最小値を原点にする
    origin = mesh.vertices.min(axis=0)
    mesh.vertices = mesh.vertices - origin
    mesh = to_godot_axes(mesh)
    mesh.metadata["origin"] = origin
    mesh.metadata["stride"] = stride
    mesh.metadata["spacing"] = float(xs[1] - xs[0])
    return mesh


def main() -> None:
    parser = argparse.ArgumentParser(description="標高グリッドを GLB の地形メッシュに変換する")
    parser.add_argument("input", type=Path, help="入力 (東 北 標高 のテキスト)")
    parser.add_argument("output", type=Path, help="出力 (.glb)")
    parser.add_argument("--stride", type=int, default=2, help="格子を何個おきに使うか (大きいほど軽くなる)")
    args = parser.parse_args()

    xs, ys, z = load_dem(args.input)
    print(f"読み込み: {z.shape[1]} x {z.shape[0]} の格子 (欠け {int(np.isnan(z).sum()):,})")
    write_outputs(convert(xs, ys, z, args.stride), args.output)


if __name__ == "__main__":
    main()
