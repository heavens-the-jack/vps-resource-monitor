# 要件・現状

初版作成日: 2026-09-07（`docs/HANDOFF.md` を rename して継続更新している）。

## 背景・目的

自己ホストしている別アプリが動く本番VPSで、メモリ逼迫・スワップ多用により
`git`コマンド等のプロセス起動が数秒〜10秒以上遅延する事象が発生した。調査の結果、VPSの物理メモリが
約960MBしかなく、スワップを1GB以上使う状態だったことが直接原因と判明した。

この「VPSのリソース状況を後から振り返れるようにしたい」というニーズ自体は、特定のアプリに依存しない
汎用的なものであるため、そのアプリ本体からは完全に切り離し、独立したツールとして管理することにした。

## 要件

- ホスト（OS/物理マシン）レベルのメモリ・スワップ・CPU負荷（load average / CPU使用率）を継続的に監視し、
  閾値を継続して超過した場合に検知できること
- メール送信基盤に依存しないこと。通知は任意で、Healthchecks（セルフホスト可）へ送る。
  設定しなくても `/var/log/monit.log` と `monit status` で確認できること
- 通知を有効にしたとき、異常を即時に、また VPS や Monit の停止を ping の途絶えとして検知できること
- 監視対象は「ホストのリソース状況」のみ。同じホスト上で動く個別アプリには依存しないこと
- Docker コンテナ化し、Kamal でデプロイすること
- HTTP を外部に公開しない常駐デーモンとして動作すること（Kamal の `proxy` は使わない）
- 複数VPSを管理・切り替えられること（VPSごとの接続先はKamalの`destination`機能で外だしし、
  `config/deploy.yml`本体を変更せずにVPSを追加・切り替えできること）

## 現状

- `Dockerfile`・`config/monitrc`：ローカルで**ビルド・起動・`monit -t`構文チェック・`monit status`実行まで動作確認済み**。メモリ・スワップ・load averageが正しく取得できることを確認した
- `config/deploy.yml`：Kamalのデプロイ設定を用意（ベース、`hosts`・`ssh`は持たない）
- `config/deploy.sample.yml`：VPSごとの接続情報（`hosts`・`ssh`）のテンプレート。実ファイル（`config/deploy.<destination名>.yml`）は`.gitignore`で除外
- `test/readiness_test.sh`：コンテナが Kamal のタイムアウト内に `healthy` になることを検証する回帰テストを追加（下記「対応済み」参照）
- `test/destination_test.sh`：destinationでVPSの`hosts`を切り替えられることを検証する回帰テストを追加（下記「対応済み」参照）

## 対応済み

### `kamal setup` の初回失敗（readiness レース） — 2026-09-07

初回 `kamal setup` が `target failed to become healthy within configured timeout (30s)` で失敗した。

- 原因：`config/monitrc` の `set daemon 60 with start delay 30` により Monit の httpd(2812) が
  起動後30秒間 LISTEN せず、その間 Dockerfile の HEALTHCHECK（`monit status` = localhost:2812 へ接続）が
  `Connection refused` で失敗し続けた。コンテナが `healthy` になる前に Kamal の `deploy_timeout`（デフォルト30秒）が
  満了し、Kamal がコンテナを停止・ロールバックしていた。
- 対応：
  1. `config/monitrc` から `with start delay 30` を削除（コンテナ環境では不要なオプション）
  2. `config/deploy.yml` に `deploy_timeout: 60` を明示（余裕マージン）
- 検証：`bash test/readiness_test.sh` で、コンテナが約6秒で `healthy` になることを確認（閾値25秒）
- 詳細な設計は `docs/design.md` を参照

### `kamal setup` の再失敗（kamal-proxy の HTTP ヘルスチェック） — 2026-09-07

上記対応後の再実行で、コンテナの Docker HEALTHCHECK は即座に成功するようになったが、
その次の段階で `First web container is unhealthy` / `target failed to become healthy within configured timeout (1m0s)` で失敗した。

- 原因：`config/deploy.yml` に `proxy` の指定が無く、Kamal 2 では primary role（`web`）で kamal-proxy が
  デフォルトで有効になる。kamal-proxy がコンテナの 80番ポートに対して独自の HTTP ヘルスチェック（`GET /up`）を
  行うが、このappは HTTP を一切喋らないため永久に unhealthy 判定になっていた。
- 対応：`config/deploy.yml` の `servers.web` を `hosts:` 形式に展開し、`proxy: false` を指定
  （primary role で proxy を無効化する Kamal の記法）。kamal-proxy によるルーティング・HTTPヘルスチェックを
  行わず、死活判定は Dockerfile の `HEALTHCHECK`（`docker inspect .State.Health`）だけに委ねる。
- 他サービスへの影響：`proxy: false` により本サービスの `proxy_hosts` は空になり、`kamal setup` / `kamal deploy` は
  共有の `kamal-proxy` コンテナに一切触れない（`kamal config` / kamal ライブラリで `running_proxy? = false`,
  `proxy_hosts = []` を確認済み）。同一ホストで稼働する他アプリのルーティングには影響しない。
  ただし `kamal proxy reboot` / `kamal proxy upgrade` / `kamal remove` は共有 proxy を操作するため本プロジェクトから実行しないこと。
- 詳細な設計は `docs/design.md` を参照
- 結果：上記2件の対応後、本番VPSで `kamal setup` が正常終了することを確認（2026-09-07）。
  ローカルレジストリ（`localhost:5555`）の共用も問題なく動作した。

### 複数VPS対応（Kamal destination化） — 2026-09-17

複数のVPSを管理・切り替えたいという要望を受け、`servers.web.hosts`・`ssh`を`config/deploy.yml`
（ベース）から`config/deploy.<destination名>.yml`へ切り出した。

- 対応：`config/deploy.yml`から`hosts`・`ssh`を削除し、VPSごとの接続情報は各自が
  `config/deploy.sample.yml`をコピーして作成する`config/deploy.<destination名>.yml`に記載する
  運用にした（`.gitignore`で除外、実ファイルはコミットされない）。以降のkamalコマンドは
  `-d <destination名>`のように必ずdestinationを指定する
- 新しいVPSを追加する場合は`config/deploy.<destination名>.yml`を追加するだけでよく、
  `config/deploy.yml`側の変更は不要
- 検証：`bash test/destination_test.sh`で、destination未指定時にエラーになること、
  一時的なdestinationファイル（ダミーホスト）で正しく`hosts`が反映されることを確認
- 詳細な設計は`docs/design.md`の「複数VPSの管理（Kamal destination）」を参照

**追加トラブル対応（本番反映時）**：destination未使用の運用からdestinationへ移行する際、
本番VPSで`kamal deploy`実行前に`kamal status -d <destination名>`を試したところ
`No such container`エラーが発生した。原因はKamalのコンテナ名が
`[service名, role名, destination名].join("-")`で決まるため、destination導入により
既存の稼働中コンテナ（destinationなしのprefix）とは別名になったこと。さらに調査の結果、
Kamalの新旧入れ替えロジックは同一prefixのコンテナしか検出しないため、`kamal deploy -d <destination名>`を
実行しても旧コンテナは自動停止されずそのまま残ることが判明した。
対応として、`kamal deploy -d <destination名>`実行後に新コンテナのhealthyを確認したうえで、
旧コンテナ（destinationなしのprefixを持つコンテナ）を`docker rm -f`で手動削除し、
切り替えを完了した（2026-09-17）。詳細・今後の注意点は`docs/design.md`の該当節を参照。

### Healthchecks への通知 — 2026-10-30

Monit のメール通知は未整備のままだったため、通知を Healthchecks に寄せた。
`bin/hc-notify` と `docker-entrypoint` を追加し、`config/monitrc` を更新した。
設計は `docs/design.md`、検証は `test/notify_test.sh`。

## 未確認・未検証のこと

1. **`kamal deploy`（2回目以降）の動作**：`kamal setup` は完走したが、更新時の `kamal deploy` /
   ロールバック挙動はまだ実運用で通していない
2. **閾値のチューニング**：`config/monitrc`の閾値（メモリ90%・スワップ70%・load average 4等）は初期値。実際にデプロイして数日〜数週間分のデータを見てから調整するのが望ましい
3. **Healthchecks 通知の本番動作**：ローカルでは、ダミーの受け口と本物の Healthchecks（v5.0.3）への送信まで確認済み（2026-10-30）。
   本番の Healthchecks 経由のメール通知は未確認
4. **メール通知（Monit 直接）**：設定しない。通知は Healthchecks に寄せる

## 参考情報

- 対象VPS：`config/deploy.<destination名>.yml`（各自作成、`.gitignore`対象）に記載
- Monitの公式ドキュメント：https://mmonit.com/monit/documentation/monit.html
- Kamalの公式ドキュメント：https://kamal-deploy.org/
