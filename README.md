# vps-resource-monitor

VPS本体（OS/ホストレベル）のメモリ・スワップ・CPU負荷を監視する、軽量な自己完結型ツール。
[Monit](https://mmonit.com/monit/) をDockerコンテナ化し、[Kamal](https://kamal-deploy.org/) でデプロイする。

外部SaaS・追加のメール送信基盤には依存しない。特定のアプリケーションから独立しており、
同じホスト上で稼働する任意のアプリとは無関係に、ホストのリソース状況だけを見る。

## 構成

```
vps-resource-monitor/
├── Dockerfile              # Monitを動かす最小イメージ
├── LICENSE.txt
├── config/
│   ├── monitrc             # Monitの監視ルール本体
│   ├── deploy.yml          # Kamalのデプロイ設定（ベース、hostsは持たない）
│   └── deploy.sample.yml   # VPSごとの接続情報テンプレート（コピーして使う）
├── test/
│   ├── readiness_test.sh   # コンテナが素早くhealthyになることの回帰テスト
│   └── destination_test.sh # destinationでhostsが切り替わることの回帰テスト
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
```

- `readiness_test.sh`：コンテナが Kamal のタイムアウト内に `healthy` になることを検証する回帰テスト（docker が必要）
- `destination_test.sh`：destination指定でVPSのhostsが正しく切り替わることを検証する回帰テスト（kamal が必要）

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

現時点ではメール通知は**未設定**（SMTP未整備のため）。`kamal status`（コンテナ内で `monit status`）と `/var/log/monit.log` の確認で運用する。

~~簡易Web UI（コンテナ内localhostのみ、ポート2812）を SSH ポートフォワードでブラウザから開く~~
→ この httpd はコンテナ内 localhost バインドかつポート未公開で、`monit` CLI 専用。ブラウザ閲覧はしない方針（`docs/design.md` 参照）。

将来メール通知を追加する場合は `config/monitrc` に `set mailserver` と各チェックへの通知先アドレスを追記する。
