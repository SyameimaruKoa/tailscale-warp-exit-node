# 実装履歴

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
