"""テストとサンプル用の、人工の点群。"""

import numpy as np


def synthetic_cloud(seed: int = 0) -> np.ndarray:
    """床 (20m x 20m) と壁 (x=10、高さ 3m) に、離れた場所のノイズ点を足した点群。"""
    rng = np.random.default_rng(seed)
    floor = np.column_stack([rng.uniform(0, 20, 40000), rng.uniform(0, 20, 40000), rng.normal(0, 0.01, 40000)])
    wall = np.column_stack([rng.normal(10, 0.01, 8000), rng.uniform(0, 20, 8000), rng.uniform(0, 3, 8000)])
    noise = rng.uniform([0, 0, 5], [20, 20, 8], (30, 3))  # 宙に浮いた点
    return np.concatenate([floor, wall, noise])
