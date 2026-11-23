# tools

点群や標高グリッドを、Godot で歩けるメッシュ (GLB) に変換するスクリプト。

| スクリプト | 入力 | 向いているデータ |
|---|---|---|
| `pointcloud_to_mesh.py` | LAS / LAZ / PLY の点群 | 建物や壁などの立体。ボクセルの表面にするので角ばる |
| `dem_to_mesh.py` | 「東 北 標高」の等間隔グリッド (テキスト) | 地形。格子を三角形にするので滑らかで、面が少ない |

## セットアップ

```
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements-dev.txt
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

出力は GLB と、同じ場所の `.json` (元の原点とボクセルの大きさ)。GLB は原点付近に作り、軸も Godot 向け (Y 上向き) に入れ替えています。実際の測量座標に戻したい時は、GLB の頂点 `(x, y, z)` を `(x, -z, y)` に直してから、`.json` の `origin` を足します。`pointcloud_to_mesh.from_godot_coords(vertices, origin)` がこの計算をします。

## 変換の中身

1. 点を読み込む (必要なら範囲を切り出す)
2. ボクセルに割り当て、点が少ないボクセルを捨てる
3. つながりの小さい塊を消す
4. 隣が空いているボクセルの面だけを四角形にして、外向きのメッシュを作る
5. 測量データの Z 上向きを、Godot の Y 上向きに変換して GLB に書き出す。座標は点群の最小値を原点にし、float32 の精度落ちを避ける

見た目は角ばりますが、穴や法線の乱れが出にくく、当たり判定にそのまま使えます。

## テスト

```
cd tools && ../.venv/bin/python -m pytest
```

## サンプルの世界

人工の点群から、Godot で読み込みを確認するためのサンプル (`game/assets/sample_world.glb`) を作れます。

```
cd tools && ../.venv/bin/python make_sample_world.py
```

Godot では `scenes/world_sample.tscn` で歩けます (`godot --path game res://scenes/world_sample.tscn`)。

## 標高グリッドの変換

```
.venv/bin/python tools/dem_to_mesh.py data/raw/xxx_DEM.txt data/processed/terrain.glb --stride 2
```

`--stride` は格子を何個おきに使うか。0.5m 間隔のデータを `--stride 2` にすると 1m 間隔になり、面の数が約 4 分の 1 になります。

変換後のデータは `data/processed/` に置きます (git の管理外)。

## 変換したデータで歩く

取り込みを通さず、起動時に GLB の場所を渡します。データをリポジトリに入れずに試せます。

```
godot --path game res://scenes/world_local.tscn -- --world=/絶対パス/terrain.glb
```

世界の中央の上空から降りて、地面に立ちます。

## 出典の表示

`--credit` と `--license-url` を付けると、GLB の隣の `.json` に出典が書かれ、ゲームのタイトル画面の隅とクレジットに表示されます。出典の表示が必要なデータ (CC BY など) は、必ず付けてください。

同じ `.json` に、世界の名前 `world_id` も書かれます。セーブはこの名前で世界を見分けるので、同じ場所を作り直しても、続きから遊べます。入力の名前にタイル番号 (例: `08OF3006`) があればそれと、入力全体の南西の角から自動で決まり、`--world-id 名前` で自分で決めることもできます (英数字と `.` `_` `-` の 64 文字まで、先頭に `.` は使えません)。切り出し (`--crop`) やメッシュの細かさは、名前に影響しません。ただし、メッシュの原点は動くので、ゲームは、保存した位置を新しい原点に合わせて直します (水平の原点が動いた時は、確かめた所の地図は使いません。直した位置が、作り直した世界の範囲の外になる時は、保存した位置は使わず、いつもの始まりになります)。入力の範囲を取り直して、南西の角が変わる時は、名前も変わるので、前のセーブを引き継ぎたければ `--world-id` で、前と同じ名前を渡してください。

```
.venv/bin/python tools/dem_to_mesh.py data/raw/xxx_DEM.txt data/processed/terrain.glb \
  --credit "VIRTUAL SHIZUOKA (静岡県) を加工して作成 / CC BY 4.0" \
  --license-url https://creativecommons.org/licenses/by/4.0/
```

出典の文は、データごとに `docs/data-sources.md` の「出典表示」に合わせます。

## 法線 (面の向き)

書き出す GLB には、頂点の法線を必ず入れます。法線がないと、Godot は全ての面が同じ向きだと見なして、光 (太陽、月、篝火) が、起伏と関係なく、半分の面にしか当たりません。

- 標高グリッド (`dem_to_mesh.py`): 滑らかな法線 (頂点につながる面の平均)
- 点群 (`pointcloud_to_mesh.py`): ボクセルは角ばった形なので、面ごとの法線 (頂点を面ごとに分ける。形は変わらない)

ゲーム側 (`WorldLoader`) も、法線のない GLB を読むと、読み込む時に法線を作ります (古い GLB やほかの GLB のための備えです)。
