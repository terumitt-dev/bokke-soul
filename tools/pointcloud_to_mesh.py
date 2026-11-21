"""点群 (LAS / LAZ / PLY) を、Godot で歩けるメッシュ (GLB) に変換する。

流れ: 読み込み → 切り出し → ボクセル化 → ノイズ除去 → 表面メッシュ化 → 書き出し

メッシュはボクセルの露出面をそのまま四角形にしたもの。見た目は角ばるが、
穴や法線の乱れが出にくく、当たり判定にそのまま使える。

使い方:
    python tools/pointcloud_to_mesh.py data/raw/input.laz game/assets/world.glb --voxel 0.5
"""

import argparse
import json
from pathlib import Path

import numpy as np
import trimesh
from scipy import ndimage

# ボクセル格子のセル数の上限。超える場合は範囲を切り出すか、ボクセルを大きくする
MAX_GRID_CELLS = 200_000_000


def load_points(path: Path) -> np.ndarray:
    """点の座標 (N, 3) を返す。LAS / LAZ は laspy、PLY は trimesh で読む。"""
    suffix = path.suffix.lower()
    if suffix in (".las", ".laz"):
        import laspy

        las = laspy.read(path)
        return np.column_stack([las.x, las.y, las.z]).astype(np.float64)
    if suffix == ".ply":
        cloud = trimesh.load(path)
        return np.asarray(cloud.vertices, dtype=np.float64)
    raise ValueError(f"未対応の形式です: {suffix} (LAS / LAZ / PLY)")


def crop(points: np.ndarray, bounds: tuple[float, float, float, float] | None) -> np.ndarray:
    """XY 平面で範囲 (xmin, ymin, xmax, ymax) を切り出す。"""
    if bounds is None:
        return points
    xmin, ymin, xmax, ymax = bounds
    mask = (points[:, 0] >= xmin) & (points[:, 0] <= xmax) & (points[:, 1] >= ymin) & (points[:, 1] <= ymax)
    return points[mask]


def voxelize(points: np.ndarray, voxel_size: float, min_points: int) -> tuple[np.ndarray, np.ndarray]:
    """点をボクセルに割り当て、点が min_points 個未満のボクセルは捨てる。

    返り値は (ボクセル番号 (M, 3), 格子の原点座標 (3,))。
    """
    origin = points.min(axis=0)
    index = np.floor((points - origin) / voxel_size).astype(np.int64)
    voxels, counts = np.unique(index, axis=0, return_counts=True)
    return voxels[counts >= min_points], origin


def to_grid(voxels: np.ndarray) -> np.ndarray:
    """ボクセル番号を 3 次元の真偽配列にする。"""
    if len(voxels) == 0:
        raise ValueError("ボクセルが残りませんでした。--min-points を下げるか、--voxel を大きくしてください")
    shape = tuple(voxels.max(axis=0) + 1)
    if np.prod(shape, dtype=np.int64) > MAX_GRID_CELLS:
        raise ValueError(
            f"格子が大きすぎます ({shape})。--crop で範囲を絞るか、--voxel を大きくしてください"
        )
    grid = np.zeros(shape, dtype=bool)
    grid[tuple(voxels.T)] = True
    return grid


def remove_small_components(grid: np.ndarray, min_size: int) -> np.ndarray:
    """つながったボクセルの塊のうち、min_size 個未満のものを消す (宙に浮いたノイズ対策)。"""
    if min_size <= 1:
        return grid
    labels, count = ndimage.label(grid, structure=np.ones((3, 3, 3), dtype=bool))
    sizes = ndimage.sum(grid, labels, index=np.arange(1, count + 1))
    keep = np.concatenate([[False], sizes >= min_size])
    return keep[labels]


def surface_mesh(grid: np.ndarray, voxel_size: float, origin: np.ndarray) -> trimesh.Trimesh:
    """隣が空いているボクセルの面だけを四角形にして、外向きのメッシュを作る。"""
    padded = np.pad(grid, 1)
    vertices: list[np.ndarray] = []
    faces: list[np.ndarray] = []
    offset = 0

    for axis in range(3):
        u, v = (axis + 1) % 3, (axis + 2) % 3
        for sign in (1, -1):
            # この向きの隣が空いているボクセルを探す
            neighbor = np.roll(padded, -sign, axis=axis)
            exposed = np.argwhere(padded & ~neighbor) - 1
            if len(exposed) == 0:
                continue

            plane = exposed[:, axis] + (1 if sign > 0 else 0)
            corners = []
            for du, dv in ((0, 0), (1, 0), (1, 1), (0, 1)):
                p = np.zeros((len(exposed), 3), dtype=np.float64)
                p[:, axis] = plane
                p[:, u] = exposed[:, u] + du
                p[:, v] = exposed[:, v] + dv
                corners.append(p)

            n = len(exposed)
            quad = np.stack(corners, axis=1).reshape(-1, 3)
            base = offset + np.arange(n) * 4
            # (u, v) の順が axis 方向の正の向き。負の向きは巻き方向を逆にする
            order = [(0, 1, 2), (0, 2, 3)] if sign > 0 else [(0, 2, 1), (0, 3, 2)]
            for tri in order:
                faces.append(np.stack([base + tri[0], base + tri[1], base + tri[2]], axis=1))
            vertices.append(quad)
            offset += n * 4

    mesh = trimesh.Trimesh(
        vertices=np.concatenate(vertices) * voxel_size + origin,
        faces=np.concatenate(faces),
        process=True,
    )
    return mesh


def to_godot_axes(mesh: trimesh.Trimesh) -> trimesh.Trimesh:
    """測量データの Z 上向きを、Godot の Y 上向きに変換する。(x, y, z) → (x, z, -y)

    この変換は回転 (行列式 +1) なので、面の巻き方向はそのまま保たれる。
    """
    mesh = mesh.copy()
    v = mesh.vertices
    mesh.vertices = np.column_stack([v[:, 0], v[:, 2], -v[:, 1]])
    return mesh


def from_godot_coords(vertices: np.ndarray, origin: np.ndarray) -> np.ndarray:
    """GLB の頂点を、元の測量座標に戻す。(x, y, z) → (x, -z, y) に直してから origin を足す。"""
    v = np.asarray(vertices, dtype=np.float64)
    return np.column_stack([v[:, 0], -v[:, 2], v[:, 1]]) + np.asarray(origin)


def convert(
    points: np.ndarray,
    voxel_size: float,
    min_points: int = 3,
    min_component: int = 50,
    bounds: tuple[float, float, float, float] | None = None,
) -> trimesh.Trimesh:
    points = crop(points, bounds)
    if len(points) == 0:
        raise ValueError("切り出した範囲に点がありません")
    voxels, origin = voxelize(points, voxel_size, min_points)
    grid = remove_small_components(to_grid(voxels), min_component)
    if not grid.any():
        raise ValueError("ノイズ除去で全て消えました。--min-component を下げてください")
    # 測量の座標は値が大きい (10^5 以上になることがある) ので、メッシュは原点付近に作る。
    # float32 の精度落ちを避けるため。元の原点は metadata に残す
    mesh = to_godot_axes(surface_mesh(grid, voxel_size, np.zeros(3)))
    mesh.metadata["origin"] = origin
    mesh.metadata["voxel_size"] = voxel_size
    return mesh


def write_outputs(mesh: trimesh.Trimesh, output: Path) -> None:
    """GLB と、元の座標に戻すための原点を書いた .json を書き出す。"""
    output.parent.mkdir(parents=True, exist_ok=True)
    mesh.export(output)
    meta = {
        "origin": [float(x) for x in mesh.metadata["origin"]],
        "axes": "GLB の (x, y, z) は、測量座標の (x, z, -y)。戻すには (x, -z, y) に直してから origin を足す",
    }
    meta.update({k: v for k, v in mesh.metadata.items() if k != "origin"})
    sidecar = output.with_suffix(".json")
    sidecar.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"書き出し: {output} (頂点 {len(mesh.vertices):,} / 面 {len(mesh.faces):,})")
    print(f"元の原点: {meta['origin']} (同じ場所に {sidecar.name} として保存)")


def main() -> None:
    parser = argparse.ArgumentParser(description="点群を GLB メッシュに変換する")
    parser.add_argument("input", type=Path, help="入力 (LAS / LAZ / PLY)")
    parser.add_argument("output", type=Path, help="出力 (.glb)")
    parser.add_argument("--voxel", type=float, default=0.5, help="ボクセルの大きさ (メートル)")
    parser.add_argument("--min-points", type=int, default=3, help="ボクセル内の最小点数 (これ未満は捨てる)")
    parser.add_argument("--min-component", type=int, default=50, help="残す塊の最小ボクセル数")
    parser.add_argument(
        "--crop", type=float, nargs=4, metavar=("XMIN", "YMIN", "XMAX", "YMAX"), help="XY の切り出し範囲"
    )
    args = parser.parse_args()

    points = load_points(args.input)
    print(f"読み込み: {len(points):,} 点")
    mesh = convert(points, args.voxel, args.min_points, args.min_component, tuple(args.crop) if args.crop else None)
    write_outputs(mesh, args.output)


if __name__ == "__main__":
    main()
