#!/usr/bin/env bash
# 回帰テスト: コンテナが THRESHOLD 秒以内に healthy になること。
# 元バグ: monitrc の `with start delay 30` で healthy 化が遅れ、kamal setup が
#         deploy_timeout(30s) でタイムアウトしていた。
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="vps-resource-monitor:test"
NAME="vps-resource-monitor-readiness-test"
THRESHOLD_SECONDS=25   # Kamal 旧デフォルト deploy_timeout(30s) より確実に速いこと

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build -t "$IMAGE" .
cleanup
docker run -d --name "$NAME" "$IMAGE" >/dev/null

start=$(date +%s)
while true; do
  status=$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)
  elapsed=$(( $(date +%s) - start ))
  [ "$status" = healthy ] && { echo "PASS: ${elapsed}s で healthy（閾値 ${THRESHOLD_SECONDS}s）"; exit 0; }
  [ "$elapsed" -ge "$THRESHOLD_SECONDS" ] && {
    echo "FAIL: ${THRESHOLD_SECONDS}s 以内に healthy にならず（status=${status}）"
    docker inspect --format '{{json .State.Health}}' "$NAME" || true
    exit 1
  }
  sleep 2
done
