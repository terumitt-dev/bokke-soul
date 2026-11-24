"""areas.json に書いた、全てのマップ (タイル) を、まとめて GLB に変換する。

名前、出典、篝火の場所は、変換のたびに同じになる (名前は areas.json、場所は平らな所を探す)。

使い方:
    python tools/build_areas.py data/raw/virtual-shizuoka data/processed --stride 2
"""

import argparse
import json
from argparse import Namespace
from pathlib import Path

import numpy as np

from dem_to_mesh import convert, load_dem
from pointcloud_to_mesh import apply_credit, apply_name, apply_world_id, write_outputs

MANIFEST = Path(__file__).with_name("areas.json")


def load_manifest(path: Path = MANIFEST) -> dict:
    """areas.json を読んで、確かめる (名前とタイルが、空でなく、重ならない)。"""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    areas = manifest["areas"]
    if not areas:
        raise ValueError("areas が空です")
    for key in ("tile", "name"):
        values = [area.get(key, "").strip() for area in areas]
        if not all(values):
            raise ValueError(f"{key} が空のマップがあります")
        if len(set(values)) != len(values):
            raise ValueError(f"{key} が重なっています")
    return manifest


def dem_path(raw_root: Path, manifest: dict, tile: str) -> Path:
    return raw_root / f"{manifest['source']}-{tile}" / f"{tile}_DEM.txt"


def stitch(grids: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]) -> dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]]:
    """隣り合うタイルの継ぎ目を閉じる。各タイルに、東と北の隣の、最初の 1 列と 1 行を足す。

    元データのタイルは、同じ格子の上で、ちょうど隣り合っている (東の隣の最初の列は、このタイルの最後の列の、格子 1 つ先)。
    そのまま変換すると、隣との間に、格子 1 つ分 (間引くと、もっと) の隙間ができて、つなぐと、そこへ落ちる。
    隣の最初の 1 列を足して、メッシュを隣の端まで伸ばせば、隣のメッシュと、端がそろう。
    北東の角は、斜めの隣があれば、その値、なければ欠け (その 1 マスだけ、面を作らない)。
    """
    result = {}
    for tile, (xs, ys, z) in grids.items():
        dx, dy = float(xs[1] - xs[0]), float(ys[1] - ys[0])
        east = _find(grids, lambda o: np.isclose(o[0][0] - xs[-1], dx, atol=1e-3) and _same_axis(o[1], ys))
        north = _find(grids, lambda o: np.isclose(o[1][0] - ys[-1], dy, atol=1e-3) and _same_axis(o[0], xs))
        if east is not None:
            xs, z = np.append(xs, east[0][0]), np.column_stack([z, east[2][:, 0]])
        if north is not None:
            corner = np.nan
            if east is not None:
                diagonal = _find(grids, lambda o: np.isclose(o[0][0], east[0][0], atol=1e-3) and np.isclose(o[1][0], north[1][0], atol=1e-3))
                if diagonal is not None:
                    corner = diagonal[2][0, 0]
            row = north[2][0, :]
            if east is not None:
                row = np.append(row, corner)
            ys, z = np.append(ys, north[1][0]), np.vstack([z, row])
        result[tile] = (xs, ys, z)
    return result


def _find(grids: dict, predicate) -> tuple | None:
    for grid in grids.values():
        if predicate(grid):
            return grid
    return None


def _same_axis(a: np.ndarray, b: np.ndarray) -> bool:
    return len(a) == len(b) and np.allclose(a, b, atol=1e-3)


def build(raw_root: Path, out_dir: Path, stride: int, manifest: dict | None = None) -> list[Path]:
    manifest = manifest or load_manifest()
    sources = {area["tile"]: dem_path(raw_root, manifest, area["tile"]) for area in manifest["areas"]}
    original = {tile: load_dem(path) for tile, path in sources.items()}
    grids = stitch(original)
    outputs = []
    for area in manifest["areas"]:
        tile = area["tile"]
        xs, ys, z = grids[tile]
        mesh = convert(xs, ys, z, stride)
        apply_credit(mesh, Namespace(credit=manifest["credit"], license_url=manifest["license_url"]))
        apply_name(mesh, Namespace(name=area["name"]))
        if manifest.get("crs"):
            mesh.metadata["crs"] = manifest["crs"]
        # 世界の名前は、継ぎ目を閉じる前の、元のタイルの南西の角から決める (継ぎ目を足しても、変わらない)
        apply_world_id(mesh, Namespace(world_id=None), sources[tile], np.array([original[tile][0][0], original[tile][1][0]]))
        output = out_dir / f"{tile}.glb"
        write_outputs(mesh, output)
        outputs.append(output)
    return outputs


def main() -> None:
    parser = argparse.ArgumentParser(description="areas.json の全てのマップを、GLB に変換する")
    parser.add_argument("raw_root", type=Path, help="元データの置き場 (例: data/raw/virtual-shizuoka)")
    parser.add_argument("out_dir", type=Path, help="出力の置き場 (例: data/processed)")
    parser.add_argument("--stride", type=int, default=2, help="格子を何個おきに使うか")
    args = parser.parse_args()
    build(args.raw_root, args.out_dir, args.stride)


if __name__ == "__main__":
    main()
