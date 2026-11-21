#!/bin/sh
# Godot のテストを 1 つ実行する。使い方: sh game/tests/run.sh <テスト名>  (例: walk_test)
#
# godot --script は、テストのスクリプトに文法のエラーがあっても、終了コード 0 で終わってしまう。
# そのままだと、壊れたテストが「成功」に見えるので、出力も見て、次の場合は失敗にする。
#   - 終了コードが 0 でない (テストの失敗)
#   - スクリプトのエラー、読み込みの失敗が出ている
#   - PASS が 1 件もない (テストが 1 つも動いていない)
name="$1"
if [ -z "$name" ]; then
  echo "使い方: sh game/tests/run.sh <テスト名>"
  exit 2
fi

output=$(godot --headless --path game --script "res://tests/$name.gd" 2>&1)
code=$?
printf '%s\n' "$output"

if [ "$code" -ne 0 ]; then
  exit "$code"
fi
case "$output" in
  *"SCRIPT ERROR"* | *"Failed to load script"* | *"Parse Error"*)
    echo "NG: テストのスクリプトにエラーがあります ($name)"
    exit 1
    ;;
esac
case "$output" in
  *"PASS "*) ;;
  *)
    echo "NG: PASS が 1 件もありません。テストが動いていません ($name)"
    exit 1
    ;;
esac
