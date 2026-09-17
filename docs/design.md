# 設計

## 全体構成

```
Dockerfile ── debian:bookworm-slim + monit
  │  CMD: monit -Ic /etc/monit/monitrc   （-I: フォアグラウンド実行）
  │  HEALTHCHECK: monit status            （= localhost:2812 へ接続して死活判定）
  │
config/monitrc ── 監視ルール本体
  │  set daemon 60                        （60秒周期でポーリング）
  │  set httpd port 2812 / use address localhost / allow localhost
  │                                       （monit CLI 用の制御 httpd。コンテナ内localhostのみ）
  │  check system vps-host { memory / swap / loadavg / cpu の閾値 }
  │
config/deploy.yml ── Kamal 設定（ベース、hosts は持たない）
     servers.web.proxy: false             （web ロールで kamal-proxy を使わない。下記参照）
     deploy_timeout: 60                   （healthy 待ちの上限）
config/deploy.<destination>.yml ── VPSごとの hosts（destination機能。下記参照）
```

このappは HTTP を一切喋らない常駐デーモンのため、Kamal の `proxy`（ルーティング・SSL終端）は持たない。
デプロイ時の死活判定は Dockerfile の `HEALTHCHECK` に委ね、Kamal は `docker inspect .State.Health` を
ポーリングして `healthy` を待つ。

### `proxy: false` を指定する理由と記法

Kamal 2 では primary role（`web`）は `proxy` を省略すると kamal-proxy がデフォルトで有効になる。
kamal-proxy はコンテナの 80番ポートに対して独自の HTTP ヘルスチェック（`GET /up`）を行うため、
HTTP を喋らないこのappでは `First web container is unhealthy` となりデプロイが失敗する
（`target failed to become healthy within configured timeout (1m0s)`）。

記法：primary role で proxy を無効化するには、`servers.web` を hash 形式に展開して
`proxy: false` を置く（トップレベルの `proxy` は hash 専用で `false` は不可 → `proxy: should be a hash`）。

```yaml
servers:
  web:
    hosts:
      - <host>
    proxy: false
```

（`hosts` は destinationファイル側の値とdeep mergeされる。下記「複数VPSの管理」参照）

これにより kamal-proxy を経由せず、Dockerfile の `HEALTHCHECK`（`docker inspect .State.Health`）のみで
死活判定する構成になる。

### 共有 kamal-proxy / 他サービスへの影響

`kamal-proxy` はホストに1つの共有コンテナで、同一ホストで稼働する他アプリも利用している。
`proxy: false` により本サービスの `proxy_hosts` は空になり、`kamal setup` / `kamal deploy` は
proxy 関連の処理（`kamal proxy boot` の実体）を一切実行しない（`on([])` で何もしない）。
そのため共有 `kamal-proxy` コンテナや他アプリのルート登録には影響しない。
`docker network create kamal` だけは全ホストで実行されるが、既存ネットワークがあれば冪等（エラーは握りつぶす）。

※ `kamal proxy reboot` / `kamal proxy upgrade` / `kamal remove` は共有 proxy を操作するため、
本プロジェクトからは実行しないこと。

### 状態確認の手段

~~Monit の簡易 Web UI（localhost:2812）へ SSH ポートフォワードでアクセスする~~
→ ポート2812の httpd はコンテナ内 localhost バインドかつ未公開で、`monit` CLI 専用。ブラウザ閲覧はしない。

- 状態確認：`kamal status`（= コンテナ内で `monit status` を実行。Web UI と同じ内容が得られる）
- アラート履歴：`kamal app exec --reuse "tail -n 100 /var/log/monit.log"`
- Monit 無印には履歴グラフ機能はなく、経緯の実体は `/var/log/monit.log`

### 複数VPSの管理（Kamal destination）

同じサービスを複数のVPSへ個別にデプロイできるよう、`servers.web.hosts` や `ssh` は
`config/deploy.yml`（ベース）には持たせず、VPSごとの `config/deploy.<destination名>.yml` に記載する。
このファイルは`.gitignore`で除外されるため、実際の接続情報がコミットされることはない
（テンプレートは `config/deploy.sample.yml` を参照）。

```yaml
# config/deploy.<destination名>.yml（例: config/deploy.production.yml）
servers:
  web:
    hosts:
      - <対象VPSのホスト名>

ssh:
  user: <対象VPSのSSHユーザー>
  config: ["~/.ssh/config"]
```

Kamalは`-d <destination名>`指定時、ベースの設定にdestinationファイルをdeep mergeする（`hosts`のような
配列キーは追記ではなく置き換え）。destination未指定で実行した場合は`hosts`が空になり
`Kamal::ConfigurationError: No servers specified for the web primary_role` でエラーになるため、
誤って意図しないVPSへ向くことはない（`test/destination_test.sh` で回帰確認）。

新しいVPSを追加する場合は、同様の形式で `config/deploy.<destination名>.yml` を追加するだけでよく、
`config/deploy.yml` 側の変更は不要。

#### 注意：destinationを新規導入・変更する際は旧コンテナの手動クリーンアップが必要

Kamalのコンテナ名は `[service名, role名, destination名].join("-")`（`container_prefix`）で決まるため、
destinationの有無やdestination名を変えると、以前稼働していたコンテナとは別名になる。

Kamalの新旧入れ替えロジック（`kamal app boot`）は、**現在指定したdestinationと同じprefixのコンテナ**
しか「既存の旧バージョン」として認識しない。そのため、destinationなしで稼働中のコンテナがある状態で
初めて `-d <destination名>` を指定してデプロイすると、旧コンテナは新旧入れ替えの対象と見なされず、
自動停止・削除されずにそのまま起動し続ける（実際に本プロジェクトでdestination未使用の運用から
destinationへ移行した際、`kamal status -d <destination名>` が `No such container` になり、
`docker ps` で旧prefixのコンテナが `healthy` のまま稼働し続けていることを確認した）。

destinationを新規導入・変更した場合は、デプロイ後に以下を必ず確認・実施すること。

1. `kamal status -d <destination名>` で新コンテナが `healthy` であることを確認
2. 旧prefixのコンテナが残っていないか `docker ps` で確認し、残っていれば手動で停止・削除する
   ```sh
   ssh -p <port> -F ~/.ssh/config <user>@<host> docker rm -f <旧コンテナ名>
   ```

なお、Kamalは通常の同一prefix内でのバージョン入れ替えでも `stop` はするが `rm` はしないため、
`Exited` 状態のコンテナが蓄積していく。これはdestination対応固有の問題ではなくKamalの既存仕様であり、
今回は対応範囲外とする。

## readiness 設計（`kamal setup` タイムアウト対策）

### 経緯

初回 `kamal setup` が `target failed to become healthy within configured timeout (30s)` で失敗した。
`config/monitrc` の `with start delay 30` により Monit の httpd が起動後30秒間 LISTEN せず、
その間 HEALTHCHECK が `Connection refused` で失敗、コンテナが `healthy` になる前に Kamal の
`deploy_timeout`（デフォルト30秒）が満了していた。

### 起動〜ルーティングまでのタイムライン（対策後）

| 時刻(概算) | 出来事 |
|-----------|--------|
| 0s | コンテナ起動、`monit -Ic` がフォアグラウンドで開始、httpd(2812) が即 LISTEN |
| 〜5s | Docker が start-period 中の短間隔（start-interval, 既定5s）で HEALTHCHECK を実行 → `monit status` 成功 |
| 〜6s | `.State.Health.Status` が `healthy` に遷移（`test/readiness_test.sh` で計測） |
| 〜6s | Kamal が `healthy` を検知し、`deploy_timeout: 60` の余裕内でデプロイ続行 |

### 設計判断

- **`monitrc` から `with start delay 30` を削除**：この遅延は「ホスト再起動直後のプロセスなだれ」を
  避けるためのオプションで、1コンテナ1プロセスの Docker 環境では不要。削除により httpd が即時 LISTEN し、
  readiness がほぼ即時になる。
- **`deploy.yml` に `deploy_timeout: 60` を明示**：起動が数秒で終わる想定でも、ビルドマシンの負荷などで
  遅延する余地を見込み、デフォルト30sから引き上げてマージンを確保する。
- Dockerfile の `HEALTHCHECK`（`--interval=60s --timeout=5s --start-period=30s --retries=3`）は変更しない。
  `start-period` 中の失敗は retries を消費しないため、httpd の立ち上がりが多少遅れても問題にならない。

## テスト

- `test/readiness_test.sh` — イメージをビルドしてコンテナを起動し、`THRESHOLD_SECONDS`（25秒）以内に
  `.State.Health.Status` が `healthy` になることを検証する回帰テスト。Kamal の旧デフォルト
  `deploy_timeout`(30秒) より確実に速いことを保証する。bash と docker のみで完結し、追加の依存はない。
- `test/destination_test.sh` — destination未指定では `kamal config` がエラーになり、
  一時的なdestinationファイル（ダミーホスト）を指定すると `hosts` が正しく反映されることを
  検証する回帰テスト。実VPSの情報には依存せず、bash とローカルインストール済みの `kamal`
  コマンドで完結する。
