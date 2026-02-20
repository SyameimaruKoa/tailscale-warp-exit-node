# Tailscale Exit Node with Cloudflare WARP

Docker Compose を使い、**Cloudflare WARP** 経由で通信する **Tailscale Exit Node** を構築するプロジェクトです。

Tailscale の Exit Node 機能を利用しつつ、インターネットへの出口を Cloudflare WARP にすることで、ホストの ISP IP アドレスを隠蔽できます。

## 特徴

- **IP 隠蔽**: インターネット通信の出口が Cloudflare WARP になるため、ホストの ISP IP が外部に露出しない
- **IPv6 対応**: ホストが IPv4 のみでも、WARP トンネル経由で IPv6 インターネットにアクセス可能
- **トークン期限切れ耐性**: 初回認証後は Tailscale の状態が永続化され、Auth Key が期限切れでもコンテナを再起動可能
- **ネットワーク自動復旧**: ウォッチドッグが WARP ゲートウェイを監視し、ネットワーク障害からの復旧時にルート再適用と Tailscale 再接続を自動実行
- **ビルド不要**: 既存の Docker イメージ（`caomingjun/warp` + 公式 `tailscale/tailscale`）を組み合わせるだけで動作

## 前提条件

- **Docker** および **Docker Compose**
- **Tailscale Auth Key**: [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys) で発行する `tskey-auth-...` 形式のキー（初回のみ必要）
- **ホスト OS のカーネルモジュール**: IPv6 NAT に必要

```bash
sudo modprobe ip6table_nat
sudo modprobe iptable_nat
```

F `/etc/modules` に追記してください。

```
ip6table_nat
iptable_nat
```

## 使い方

### 1. リポジトリのクローン

```bash
git clone https://github.com/SyameimaruKoa/tailscale-warp-exit-node.git
cd tailscale-warp-exit-node
```

### 2. `.env` ファイルの作成

```bash
cp .env.example .env
```

`.env` を編集し、Tailscale の Auth Key を設定します。

```dotenv
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxxxxxxx
```

> **Note**: Auth Key は初回認証時のみ使用されます。認証完了後は `./data_tailscale/` に状態が保存されるため、キーが期限切れになってもコンテナの再起動には影響しません。

### 3. 起動

```bash
docker compose up -d
```

### 4. Tailscale 管理画面で Exit Node を承認

[Tailscale Admin Console](https://login.tailscale.com/admin/machines) で新しいノード（`warp--<ホスト名>` の形式）が表示されるので、**Exit Node** として承認してください。

### 5. 動作確認

done Exit Node を有効にし、以下を確認します。

- [test-ipv6.com](https://test-ipv6.com/index.html.ja_JP) で IPv4/IPv6 アドレスが Cloudflare のものになっているか
- 通常のブラウジングが問題なく動作するか

## ファイル構成

| ファイル             | 説明                                                                                                             |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `docker-compose.yml` | WARP コンテナと Tailscale コンテナを定義。専用の Docker ネットワーク（`172.25.0.0/16` + `fd00:cafe::/64`）で接続 |
| `entrypoint.sh`      | Tailscale コンテナの起動スクリプト。Auth Key のスマート処理、ルーティング書き換え、NAT 設定、MSS Clamping を実行 |
| `.env.example`       | 環境変数のテンプレート                                                                                           |

## アーキテクチャ

```

  Docker Network (172.25.0.0/16 / fd00:cafe::/64)    │
                                                     │
  ┌──────────────┐       ┌────────────────────┐      │
  │   Tailscale  │──────▶│   Cloudflare WARP  │──────┼──▶ Internet
  │  (Exit Node) │  NAT  │    (Gateway)       │      │
  │  172.25.0.3  │       │    172.25.0.2       │      │
  └──────────────┘       └────────────────────┘      │
        ▲                                            │
ls
         │ Tailscale VPN
    クライアント
```

### コンテナの役割

- **WARP コンテナ** (`caomingjun/warp`): Cloudflare WARP トンネルを維持し、NAT ゲートウェイとして機能。`WARP_ENABLE_NAT=1` により NAT モードで動作
- **Tailscale コンテナ** (`tailscale/tailscale`): カーネルモードの TUN デバイスで VPN 終端として動作し、Exit Node を提供

### 通信の流れ

1. クライアントが Tailscale VPN 経由で Tailscale コンテナに接続
2. Tailscale コンテナが `iptables MASQUERADE` で送信元 IP を自身のアドレスに変換（NAT）
3. デフォルトゲートウェイを WARP コンテナ（`172.25.0.2`）に向けてパケットを転送
4. WARP コンテナが Cloudflare WARP トンネル経由でインターネットに送出

### 主要な技術的対策

| 対策                           | 詳細                                                                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| **NAT (Masquerade)**           | Tailscale コンテナから WARP コンテナへの通信で送信元 IP を書き換え、戻りパケットが正しくルーティングされるようにする |
| **MSS Clamping**               | VPN in VPN 構成のオーバーヘッドによるパケット詰まりを防ぐため、TCP MSS を 1120 に制限                                |
| **MTU 調整**                   | `TS_DEBUG_MTU=1280`（IPv6 最小 MTU）に設定し、パケット分断を回避                                                     |
| **遅延セットアップ**           | Tailscale 起動 10 秒後にルーティングを上書き（Tailscale が起動時にルーティングテーブルを書き換えるため）             |
| **Auth Key スマート処理**      | 既存の状態ファイルがある場合は `TS_AUTHKEY` を無視し、期限切れキーによる起動失敗を防止                               |
| **ネットワークウォッチドッグ** | WARP ゲートウェイへの疎通を 15 秒間隔で監視。復旧検知時にルート再適用と `tailscaled` への SIGHUP で即座に再接続      |
| **WARP ヘルスチェック**        | Docker ヘルスチェックで WARP の接続状態を監視。Tailscale コンテナは WARP が healthy になるまで起動を待機             |

## トラブルシューティング

### `IPv6 NAT failed` のログが出る

 OS で `sudo modprobe ip6table_nat` を実行してください。

### 接続できるがインターネットにアクセスできない

```bash
docker logs tailscale
```

`Background: Setup COMPLETE.` が出力されているか確認してください。出ていない場合、WARP コンテナが起動していない可能性があります。

### 速度が遅い

MSS Clamping の値を調整してみてください。`entrypoint.sh` 内の `--set-mss 1120` を `1100` や `1080` に変更して試してください。

### ルーター再起動後にノードがオフラインのまま

`docker logs tailscale` で `Watchdog: Network recovered!` のログを確認してください。通常は 15 秒以内にウォッチドッグが検知し、自動復旧します。長時間回復しない場合は WARP コンテナの状態を確認してください。

```bash
docker inspect --format='{{.State.Health.Status}}' warp
```

### Auth Key 関連のエラー

- **初回起動時**: 有効な `TS_AUTHKEY` が `.env` に設定されている必要があります
- **再起動時**: `./data_tailscale/` に状態が保存されていれば Auth Key は不要です。期限切れキーが `.env` に残っていても問題ありません

## ライセンス

MIT
