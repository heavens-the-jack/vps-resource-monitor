#!/usr/bin/env bash
# 回帰テスト: Healthchecks への通知（bin/hc-notify、docker-entrypoint、monitrc の exec/program 連携）。
# ダミーの受け口（Python）を立て、届いた URL と本文を確認する。実際の Healthchecks には送らない。
#   1. HC_PING_URL 未設定: 何も送らず、Monit は healthy のまま
#   2. 正常時の beat: 成功の ping（/fail なし）に状態が載る
#   3. 異常時: /fail が届き、原因が本文に載る（then exec と beat の両方）
#   4. 送信先に届かない: Monit は healthy のまま、失敗がログに残る
set -uo pipefail

cd "$(dirname "$0")/.."

IMAGE="vps-resource-monitor:test"
ALERTING="vps-resource-monitor:notify-alerting" # 閾値を 0% にして必ず異常にする
NET="vrm-notify-test-net"
STUB="vrm-notify-stub"
FAILED=0

cleanup() {
  docker rm -f "$STUB" vrm-notify-a vrm-notify-b vrm-notify-c vrm-notify-d >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

check() {  # $1: 説明、$2: 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILED=1; fi
}

docker build -q -t "$IMAGE" . >/dev/null
docker build -q -t "$ALERTING" -f - . >/dev/null <<EOD
FROM $IMAGE
COPY test/monitrc.notify-test /etc/monit/monitrc
RUN chmod 600 /etc/monit/monitrc
EOD

docker network create "$NET" >/dev/null
# 受け口: リクエストのパスと本文を /tmp/requests.log に1行ずつ記録する
docker run -d --name "$STUB" --network "$NET" python:3.12-alpine python -u -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode().replace("\n", " | ")
        open("/tmp/requests.log", "a").write(self.path + " " + body + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"OK")
    def log_message(self, *a): pass
http.server.HTTPServer(("", 8080), H).serve_forever()
' >/dev/null
sleep 2
requests() { docker exec "$STUB" cat /tmp/requests.log 2>/dev/null || true; }
# grep -q が早く終わると pipefail で失敗扱いになるため、一度変数に取ってから判定する
has() { local all; all=$(requests); grep -q -- "$1" <<<"$all"; }
wait_for() {  # $1: grep パターン、$2: 最大秒数
  for _ in $(seq 1 "$2"); do has "$1" && return 0; sleep 1; done
  return 1
}

# 1. 未設定
docker run -d --name vrm-notify-a --network "$NET" "$ALERTING" >/dev/null
sleep 6
[ -z "$(requests)" ]; check "HC_PING_URL 未設定なら何も送らない" $?
docker exec vrm-notify-a monit status >/dev/null; check "未設定でも Monit は動く" $?
docker rm -f vrm-notify-a >/dev/null

# 2. 正常時の beat（本番の monitrc は閾値内なので異常にならない。周期が長いので手動で beat を実行する）
docker run -d --name vrm-notify-b --network "$NET" -e HC_PING_URL="http://$STUB:8080/ping/ok-uuid" "$IMAGE" >/dev/null
sleep 6
docker exec vrm-notify-b hc-notify beat
wait_for "^/ping/ok-uuid .*vps-host" 5; check "正常時の beat が成功の ping で届き、状態が載る" $?
! has "/fail";                       check "正常時は /fail が届かない" $?
docker rm -f vrm-notify-b >/dev/null

# 3. 異常時（閾値 0% で必ず超過）
docker run -d --name vrm-notify-c --network "$NET" -e HC_PING_URL="http://$STUB:8080/ping/ng-uuid" "$ALERTING" >/dev/null
wait_for "^/ping/ng-uuid/fail .*vps-host" 20; check "異常時に then exec の /fail が届く" $?
docker exec vrm-notify-c hc-notify beat
sleep 1
[ "$(requests | grep -c '^/ping/ng-uuid/fail')" -ge 2 ]; check "異常が続く間の beat は成功にならず /fail になる" $?
! has "^/ping/ng-uuid ";               check "異常時に成功の ping が届かない" $?
docker rm -f vrm-notify-c >/dev/null

# 4. 送信先に届かない
docker run -d --name vrm-notify-d --network "$NET" -e HC_PING_URL="http://unreachable.invalid/ping/x" "$ALERTING" >/dev/null
sleep 8
docker exec vrm-notify-d monit status >/dev/null; check "送信先に届かなくても Monit は動く" $?
docker exec vrm-notify-d grep -q "送信に失敗" /var/log/hc-notify.log; check "送信失敗がログに残る" $?

exit "$FAILED"
