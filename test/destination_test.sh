#!/usr/bin/env bash
# 回帰テスト: destination未指定ではエラーになり、config/deploy.<destination>.yml で
# hosts を上書きできること。
# 実VPSの情報には依存せず、テスト用の一時destinationファイル（ダミーホスト）を
# 作成・削除して検証する。
set -euo pipefail

cd "$(dirname "$0")/.."

DEST="destination_test_tmp"
DEST_FILE="config/deploy.${DEST}.yml"
DUMMY_HOST="203.0.113.10"

cleanup() { rm -f "$DEST_FILE"; }
trap cleanup EXIT

if kamal config >/dev/null 2>&1; then
  echo "FAIL: destination未指定でも成功してしまった（base の hosts が空でない）"
  exit 1
fi

cat > "$DEST_FILE" <<EOF
servers:
  web:
    hosts:
      - ${DUMMY_HOST}
EOF

actual=$(kamal config -d "$DEST" 2>/dev/null | ruby -ryaml -e 'puts YAML.load($stdin.read)[:hosts].join(",")')
if [ "$actual" != "$DUMMY_HOST" ]; then
  echo "FAIL: destination ${DEST} の hosts が期待値と異なる（期待=${DUMMY_HOST} 実際=${actual}）"
  exit 1
fi

echo "PASS: destination未指定はエラーになり、config/deploy.<destination>.yml で hosts=${actual} が反映される"
