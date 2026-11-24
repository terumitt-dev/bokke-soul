"""標高グリッド (テキスト) を、Godot で歩ける地形メッシュ (GLB) に変換する。

入力は 1 行に「東 北 標高」を並べた等間隔のグリッド (VIRTUAL SHIZUOKA の Grid の _DEM.txt など)。
点群を一度ボクセルにする pointcloud_to_mesh.py と違い、格子のまま 2 枚の三角形にするので、
地形が滑らかで、面の数も少ない。

使い方:
    python tools/dem_to_mesh.py data/raw/xxx_DEM.txt data/processed/terrain.glb --stride 2
"""

import argparse
import warnings
from pathlib import Path

import numpy as np
import trimesh
from scipy import ndimage

from pointcloud_to_mesh import (
    add_credit_arguments,
    add_name_argument,
    add_world_id_arguments,
    apply_credit,
    apply_name,
    apply_world_id,
    to_godot_axes,
    write_outputs,
)

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


# 篝火を置く場所を探す時の、既定の値 (m)
BONFIRE_MARGIN = 40.0  # マップの端から、これだけ離す (端は、隣のマップへの出口になる)
BONFIRE_RADIUS = 6.0  # この半径の中 (一辺 2 x 半径 ほどの正方形の窓) が、平らな場所を選ぶ
# 傾き (tan) の差が、これ未満なら「同じくらい平ら」と見なして、中央に近い方を選ぶ (0.01 は、約 0.57 度)
CENTER_WEIGHT = 0.01


def find_flat_spot(
    xs: np.ndarray, ys: np.ndarray, z: np.ndarray, margin: float = BONFIRE_MARGIN, radius: float = BONFIRE_RADIUS
) -> tuple[float, float, float, float]:
    """できるだけ平らな場所を探して、(東, 北, 標高, 傾き (度)) を返す。

    場所の周り (radius) の傾きの二乗平均が、いちばん小さい所を選ぶ。端から margin 以内と、
    周りに標高の欠けがある所は選ばない。同じくらい平らなら、マップの中央に近い方を選ぶ。
    """
    dx, dy = float(xs[1] - xs[0]), float(ys[1] - ys[0])
    extent = min(xs[-1] - xs[0], ys[-1] - ys[0])
    small = min(margin, extent * 0.25), min(radius, extent * 0.1)  # 小さなマップでも、置ける場所を残す
    if small != (margin, radius):
        warnings.warn(f"マップが小さいので、篝火の端からの距離を {small[0]:.1f} m、平らさを見る半径を {small[1]:.1f} m に縮めました")
    margin, radius = small
    gy, gx = np.gradient(z, dy, dx)
    slope2 = gx**2 + gy**2  # 傾き (tan) の二乗。欠けの周りは NaN
    valid = np.isfinite(slope2)
    # 窓は、東西と南北で、別々の格子間隔から決める (間隔が違う格子でも、窓が、格子より大きくならない)
    window = (2 * max(1, round(radius / dy)) + 1, 2 * max(1, round(radius / dx)) + 1)
    full = ndimage.uniform_filter(valid.astype(float), window, mode="constant") > 1 - 1e-6  # 窓の中に、欠けがない
    rms = np.sqrt(np.maximum(ndimage.uniform_filter(np.where(valid, slope2, 0.0), window, mode="constant"), 0.0))

    gx_grid, gy_grid = np.meshgrid(xs, ys)
    inside = (
        (gx_grid >= xs[0] + margin) & (gx_grid <= xs[-1] - margin) & (gy_grid >= ys[0] + margin) & (gy_grid <= ys[-1] - margin)
    )
    allowed = full & inside & valid
    if not allowed.any():
        raise ValueError("篝火を置ける場所がありません (端から離れた、欠けのない場所が必要です)")
    center = np.array([(xs[0] + xs[-1]) / 2, (ys[0] + ys[-1]) / 2])
    spread = max(xs[-1] - xs[0], ys[-1] - ys[0]) / 2
    nearness = np.hypot(gx_grid - center[0], gy_grid - center[1]) / spread
    score = np.where(allowed, rms + CENTER_WEIGHT * nearness, np.inf)  # 同じくらい平らなら、中央に近い方
    row, col = np.unravel_index(np.argmin(score), score.shape)
    return float(xs[col]), float(ys[row]), float(z[row, col]), float(np.degrees(np.arctan(rms[row, col])))


def sample_indices(count: int, stride: int, offset: int = 0) -> np.ndarray:
    """間引いて使う番号。最初と最後は、必ず使う (端が、割り切れ方で欠けない)。その間は、(番号 + offset) が stride の倍数の所。

    offset は、この格子の最初の番号が、全体の格子の何番目か (複数のタイルを、同じ格子の線で間引くため)。
    隣り合うタイルが、継ぎ目の上の、同じ位置の頂点を持つ (T 字の継ぎ目の隙間ができない)。
    """
    indices = [i for i in range(count) if i == 0 or i == count - 1 or (i + offset) % stride == 0]
    return np.array(indices)


def convert(
    xs: np.ndarray,
    ys: np.ndarray,
    z: np.ndarray,
    stride: int = 1,
    bonfire: tuple[float, float] | None = None,
    margin: float = BONFIRE_MARGIN,
    lattice: tuple[float, float] | None = None,
) -> trimesh.Trimesh:
    """格子を stride 個おきに間引いて地形メッシュにし、原点付近へ寄せて Godot の軸にする。

    篝火を置く場所 (測量座標の 東, 北, 標高) も、付属情報に入れる。bonfire (東, 北) があればそこ、なければ、平らな場所を探す。
    lattice (東, 北) は、複数のタイルに共通の、格子の原点。渡すと、全てのタイルが、同じ格子の線で間引かれる (継ぎ目がそろう)。
    """
    if stride < 1:
        raise ValueError("stride は 1 以上にしてください")
    # 篝火の場所は、間引く前の格子で決める (間引きの細かさを変えても、同じ場所になる)
    spot = _bonfire_spot(xs, ys, z, bonfire, margin)
    # 間引いても、最後の列と行は、必ず使う (端が、stride の割り切れ方で、欠けない。隣のタイルとの継ぎ目が、そろう)
    offset_x = round((xs[0] - lattice[0]) / (xs[1] - xs[0])) if lattice else 0
    offset_y = round((ys[0] - lattice[1]) / (ys[1] - ys[0])) if lattice else 0
    cols, rows = sample_indices(len(xs), stride, offset_x), sample_indices(len(ys), stride, offset_y)
    xs, ys, z = xs[cols], ys[rows], z[np.ix_(rows, cols)]
    mesh = heightfield_mesh(xs, ys, z)
    # 測量の座標は値が大きいので、float32 の精度落ちを避けて、最小値を原点にする
    origin = mesh.vertices.min(axis=0)
    mesh.vertices = mesh.vertices - origin
    mesh = to_godot_axes(mesh)
    mesh.metadata["origin"] = origin
    mesh.metadata["stride"] = stride
    mesh.metadata["spacing"] = float(xs[1] - xs[0])
    mesh.metadata["bonfire"] = [spot[0], spot[1], spot[2]]
    if np.isfinite(spot[3]):  # 場所を手で決めた時は、傾きは求めない
        mesh.metadata["bonfire_slope_deg"] = round(spot[3], 2)
    return mesh


def _bonfire_spot(
    xs: np.ndarray, ys: np.ndarray, z: np.ndarray, bonfire: tuple[float, float] | None, margin: float
) -> tuple[float, float, float, float]:
    if bonfire is None:
        return find_flat_spot(xs, ys, z, margin)
    east, north = bonfire
    if not (xs[0] <= east <= xs[-1] and ys[0] <= north <= ys[-1]):
        raise ValueError("篝火の場所が、マップの外です")
    col, row = int(np.abs(xs - east).argmin()), int(np.abs(ys - north).argmin())
    if not np.isfinite(z[row, col]):
        raise ValueError("篝火の場所に、標高がありません")
    return float(xs[col]), float(ys[row]), float(z[row, col]), float("nan")


def main() -> None:
    parser = argparse.ArgumentParser(description="標高グリッドを GLB の地形メッシュに変換する")
    parser.add_argument("input", type=Path, help="入力 (東 北 標高 のテキスト)")
    parser.add_argument("output", type=Path, help="出力 (.glb)")
    parser.add_argument("--stride", type=int, default=2, help="格子を何個おきに使うか (大きいほど軽くなる)")
    add_credit_arguments(parser)
    add_world_id_arguments(parser)
    add_name_argument(parser)
    parser.add_argument("--bonfire", type=float, nargs=2, metavar=("EAST", "NORTH"), help="篝火を置く場所 (測量座標。最寄りの格子点に寄せる)。省略すると、平らな場所を探す")
    parser.add_argument("--crs", help="座標系 (例: EPSG:6676)。.json に書く。別の座標系のデータを混ぜた時に、気づくため")
    parser.add_argument("--bonfire-margin", type=float, default=BONFIRE_MARGIN, help="篝火を置く場所を、端から離す距離 (m)")
    args = parser.parse_args()

    xs, ys, z = load_dem(args.input)
    print(f"読み込み: {z.shape[1]} x {z.shape[0]} の格子 (欠け {int(np.isnan(z).sum()):,})")
    mesh = convert(xs, ys, z, args.stride, tuple(args.bonfire) if args.bonfire else None, args.bonfire_margin)
    apply_credit(mesh, args)
    apply_name(mesh, args)
    if args.crs:
        mesh.metadata["crs"] = args.crs
    apply_world_id(mesh, args, args.input, np.array([xs[0], ys[0]]))  # 間引く前の、格子全体の角
    write_outputs(mesh, args.output)


if __name__ == "__main__":
    main()
