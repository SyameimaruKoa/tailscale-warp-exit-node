# 実装履歴

## 2026-10-27

### Tailscale自身の通信の経路分離 (Issue #1)

- **問題**: `entrypoint.sh` がデフォルトゲートウェイを WARP へ書き換えるため、`tailscaled` 自身の通信（制御プレーン・DERP・direct 接続）まで WARP 経由になり、WARP の接続状態・遅延の影響を受けていた。fwmark だけでは元のゲートウェイへ戻る保証がなかった
- **対策1**: 起動直後・書き換え前に元の Docker ゲートウェイを退避し、専用テーブル（`100`）に接続済みサブネットごと保持。`tailscaled` の bypass fwmark（`0x80000/0xff0000`、起動時にルールから自動検出）を優先度 `5200` の `ip rule` でこのテーブルへ振り分け、IPv4 / IPv6 双方で `tailscaled` 自身の通信を通常回線へ分離
- **対策2**: 専用テーブルで解決できない fwmark 付きパケットは優先度 `5201` で `unreachable` とし、WARP へフォールバックさせない。WARP 障害時も `main` のデフォルトは WARP のままにし、Exit Node 転送通信が通常回線へ漏れない従来動作を維持
- **対策3**: ウォッチドッグが毎周期、経路分離が維持されているか（`ip route get ... mark ...`）も確認し、崩れていれば再適用するよう拡張
- **対策4**: 検証用に `verify-routing.sh` を追加し、README に経路分離の仕組みと検証手順を記載。`docker-compose.yml` の Tailscale コンテナに `net.ipv4.conf.all.src_valid_mark=1` を追加
- **変更ファイル**: `entrypoint.sh`, `docker-compose.yml`, `verify-routing.sh`, `README.md`, `.env.example`, `CHANGELOG.md`

## 2026-02-20

### ネットワーク障害からの自動復旧

- **問題**: ルーター再起動等でネットワークが一時的に切断されると、復旧後も Tailscale ノードがしばらくオフラインのまま上がってこない
- **対策1**: `entrypoint.sh` にネットワークウォッチドッグを追加。WARP ゲートウェイ（`172.25.0.2`）への疎通を 15 秒間隔で監視し、復旧検知時にルートを再適用して `tailscaled` に SIGHUP を送信し即座に再接続をトリガー
- **対策2**: `docker-compose.yml` の WARP コンテナにヘルスチェックを追加（`curl` で Cloudflare に疎通確認）。Tailscale コンテナは `depends_on: condition: service_healthy` で WARP の準備完了を待機
- **対策3**: iptables ルールの重複追加を防ぐため `-C`（チェック）を事前に実行するよう変更
- **変更ファイル**: `entrypoint.sh`, `docker-compose.yml`

### Auth Key 期限切れ耐性の追加

- **問題**: `TS_AUTHKEY` が期限切れの状態でコンテナを再起動すると、`containerboot` が期限切れキーで再認証を試みて起動に失敗する
- **対策**: `entrypoint.sh` に状態ファイル（`$TS_STATE_DIR/tailscaled.state`）の存在チェックを追加。既に認証済みの場合は `TS_AUTHKEY` を `unset` し、既存の状態で起動するように変更
- **初回起動時**: `TS_AUTHKEY` が未設定かつ状態ファイルがない場合はエラーメッセージを出して終了
- **変更ファイル**: `entrypoint.sh`

### README の再構成

- ロールプレイ調の文体を削除し、事実に基づいた技術文書に書き換え
- アーキテクチャ図（ASCII）を追加
- Auth Key スマート処理の説明を追加
- 検証不可能な速度に関する記述（200Mbps超）を削除
- 通信の流れ・技術的対策を表形式で整理
- **変更ファイル**: `README.md`

### .env.example の更新

- Auth Key が初回のみ必要である旨のコメントを追加
- **変更ファイル**: `.env.example`
