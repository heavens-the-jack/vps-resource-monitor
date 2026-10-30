# vps-resource-monitor

VPS本体（OS/ホストレベル）のメモリ・スワップ・CPU負荷を監視する、軽量な自己完結型ツール。
[Monit](https://mmonit.com/monit/) をDockerコンテナ化し、[Kamal](https://kamal-deploy.org/) でデプロイする。

メール送信基盤には依存しない。通知は任意で、[Healthchecks](https://healthchecks.io/)（セルフホスト可）へ送れる。
特定のアプリケーションから独立しており、
同じホスト上で稼働する任意のアプリとは無関係に、ホストのリソース状況だけを見る。

## 構成

```
vps-resource-monitor/
├── Dockerfile              # Monitを動かす最小イメージ（monit + curl）
├── bin/
│   ├── hc-notify           # Healthchecksへ監視結果を送るスクリプト（Monitから呼ばれる）
│   └── docker-entrypoint   # HC_PING_URL をMonitが呼ぶスクリプトへ渡す
├── LICENSE.txt
├── config/
│   ├── monitrc             # Monitの監視ルール本体
│   ├── deploy.yml          # Kamalのデプロイ設定（ベース、hostsは持たない）
│   └── deploy.sample.yml   # VPSごとの接続情報テンプレート（コピーして使う）
├── test/
│   ├── readiness_test.sh   # コンテナが素早くhealthyになることの回帰テスト
│   ├── destination_test.sh # destinationでhostsが切り替わることの回帰テスト
│   ├── notify_test.sh      # Healthchecksへの通知の回帰テスト
│   └── monitrc.notify-test # notify_test.sh 用の監視設定（閾値と周期だけテスト向け）
└── docs/
    ├── requirements.md      # 背景・要件・現状・未確認事項
    └── design.md            # 構成とreadiness設計
```

## ローカルでの動作確認

```sh
docker build -t vps-resource-monitor .
docker run -d --name monit-test vps-resource-monitor
# 起動後まもなく（数秒）確認できる
docker exec monit-test monit status
docker rm -f monit-test
```

## テスト

```sh
bash test/readiness_test.sh
bash test/destination_test.sh
bash test/notify_test.sh
```

- `readiness_test.sh`：コンテナが Kamal のタイムアウト内に `healthy` になることを検証する回帰テスト（docker が必要）
- `destination_test.sh`：destination指定でVPSのhostsが正しく切り替わることを検証する回帰テスト（kamal が必要）
- `notify_test.sh`：ダミーの受け口を立て、通知が正しい URL・本文で届くこと、未設定なら何も送らないこと、送信に失敗しても Monit が動き続けることを検証する（docker が必要）

## デプロイ（Kamal）

複数VPSを`destination`で管理する。`config/deploy.yml`（ベース）には`hosts`を持たず、
VPSごとの接続情報（`hosts`・`ssh`）は`config/deploy.<destination名>.yml`に記載する。
このファイルは`.gitignore`で除外されるため、実際のホスト名・SSH接続情報がコミットされることはない。

初回セットアップ時は、テンプレートをコピーして自分のVPS向けに編集する。

```sh
cp config/deploy.sample.yml config/deploy.production.yml
# config/deploy.production.yml を対象VPSのホスト名・SSHユーザーに合わせて編集する
```

destination未指定の`kamal`コマンドは`hosts`が無くエラーになるため、必ず`-d`で指定する。
以下はプロジェクトルートで実行する（`production`の部分は任意のdestination名に読み替え）。

```sh
kamal setup -d production    # 初回のみ（サーバー構築 + 初回デプロイまで一括）
kamal deploy -d production   # 以降の更新時
kamal status -d production   # コンテナ内で monit status を実行（状態確認）
kamal logs -d production     # コンテナのログ確認
```

状態の確認は `kamal status -d <destination名>`、アラート履歴は
`kamal app exec --reuse "tail -n 100 /var/log/monit.log" -d <destination名>` で行う。

複数のVPSを管理する場合は、同様に`config/deploy.<destination名>.yml`を追加するだけでよく、
`config/deploy.yml`側の変更は不要。

**注意**：このappはHTTPを喋らないため、Kamalの`proxy`設定を持たない。詳細は `docs/design.md`、経緯・未確認事項は `docs/requirements.md` を参照。

## 監視内容・閾値

`config/monitrc` を参照。現時点の初期値：

- メモリ使用率 > 90%
- スワップ使用率 > 70%
- load average（5分平均） > 4
- CPU使用率（user） > 90%

いずれも「継続して超過した場合」に反応する（`for N cycles`）。実際の運用データを見ながら調整すること。

## 通知について

通知は Healthchecks へ送る（**任意**。`HC_PING_URL` を設定した場合のみ有効で、未設定なら送らない）。

- 異常を検知したとき（閾値の超過が `for N cycles` 続いたとき）：即時に `/fail` を送る。原因が本文に載る
- 5周期（約5分）ごと：現在の状態を送る。異常が続いていれば `/fail`、正常なら成功の ping（本文は `monit summary`）
- VPS全体や Monit が止まると送信が途絶える。それを Healthchecks 側が検知して通知する（チェックの周期は5分、猶予は10〜15分を目安にする）

有効にする手順（Kamal）：

1. Healthchecks にチェックを作り、ping URL（`https://<host>/ping/<uuid>`）を控える
2. `.kamal/secrets` に `HC_PING_URL=<ping URL>` を書く（コミットしない）
3. `config/deploy.<destination名>.yml` に `env.secret: [HC_PING_URL]` を追加する（`config/deploy.sample.yml` 参照）
4. `kamal deploy -d <destination名>`

注意：本文は Healthchecks の画面とメールに残る。載るのは状態の文字列のみで、秘密は載せない。ping URL 自体は秘密として扱う。
送信に失敗しても Monit は止まらず、`/var/log/hc-notify.log` に残る。

通知を設定しなくても、`kamal status`（コンテナ内で `monit status`）と `/var/log/monit.log` で確認できる。

~~簡易Web UI（コンテナ内localhostのみ、ポート2812）を SSH ポートフォワードでブラウザから開く~~
→ この httpd はコンテナ内 localhost バインドかつポート未公開で、`monit` CLI 専用。ブラウザ閲覧はしない方針（`docs/design.md` 参照）。
