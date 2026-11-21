# tools

点群を、Godot で歩けるメッシュ (GLB) に変換するスクリプト。

## セットアップ

```
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
```

## 使い方

```
.venv/bin/python tools/pointcloud_to_mesh.py data/raw/input.laz game/assets/world.glb --voxel 0.5
```

| オプション | 意味 | 既定値 |
|---|---|---|
| `--voxel` | ボクセルの大きさ (メートル)。小さいほど細かく、重くなる | 0.5 |
| `--min-points` | ボクセル内の点がこれ未満なら捨てる (散らばったノイズ対策) | 3 |
| `--min-component` | つながったボクセルがこれ未満の塊は消す (宙に浮いたノイズ対策) | 50 |
| `--crop XMIN YMIN XMAX YMAX` | XY の範囲を切り出す。大きな点群は先に絞る | なし |

対応形式は LAS / LAZ / PLY。

## 変換の中身

1. 点を読み込む (必要なら範囲を切り出す)
2. ボクセルに割り当て、点が少ないボクセルを捨てる
3. つながりの小さい塊を消す
4. 隣が空いているボクセルの面だけを四角形にして、外向きのメッシュを作る
5. 測量データの Z 上向きを、Godot の Y 上向きに変換して GLB に書き出す

見た目は角ばりますが、穴や法線の乱れが出にくく、当たり判定にそのまま使えます。

## テスト

```
cd tools && ../.venv/bin/python -m pytest
```
