# Tailscale Exit Node with Cloudflare WARP

Docker Compose を使い、**Cloudflare WARP** 経由で通信する **Tailscale Exit Node** を構築するプロジェクトです。

Tailscale の Exit Node 機能を利用しつつ、インターネットへの出口を Cloudflare WARP にすることで、ホストの ISP IP アドレスを隠蔽できます。

## 特徴

- **IP 隠蔽**: インターネット通信の出口が Cloudflare WARP になるため、ホストの ISP IP が外部に露出しない
- **IPv6 対応**: ホストが IPv4 のみでも、WARP トンネル経由で IPv6 インターネットにアクセス可能
- **トークン期限切れ耐性**: 初回認証後は Tailscale の状態が永続化され、Auth Key が期限切れでもコンテナを再起動可能
- **ネットワーク自動復旧**: ウォッチドッグが WARP ゲートウェイを監視し、ネットワーク障害からの復旧時にルート再適用と Tailscale 再接続を自動実行
- **経路分離**: `tailscaled` 自身の通信（制御プレーン・DERP・direct 接続）は WARP を経由せず通常回線へ送るため、WARP の状態に Tailscale の接続維持が引きずられない
- **ビルド不要**: 既存の Docker イメージ（`caomingjun/warp` + 公式 `tailscale/tailscale`）を組み合わせるだけで動作

## 前提条件

- **Docker** および **Docker Compose**
- **Tailscale Auth Key**: [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys) で発行する `tskey-auth-...` 形式のキー（初回のみ必要）
- **ホスト OS のカーネルモジュール**: IPv6 NAT に必要

```bash
sudo modprobe ip6table_nat
sudo modprobe iptable_nat
```

`/etc/modules` に追記してください。

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

### 6. 経路分離の検証

`tailscaled` 自身の通信が通常回線へ、Exit Node の転送通信が WARP へ分離されているかを検証します。

```bash
docker compose exec tailscale sh /verify-routing.sh
```

手動で確認する場合は以下です（`mark` 付きが元の Docker ゲートウェイ、なしが WARP `10.1.0.2` / `fd6a:204b:1e8d::2` を向けば正常です）。

```bash
docker compose exec tailscale ip rule
docker compose exec tailscale ip route get 1.1.1.1 mark 0x80000
docker compose exec tailscale ip route get 1.1.1.1
docker compose exec tailscale ip -6 route get 2606:4700:4700::1111 mark 0x80000
docker compose exec tailscale ip -6 route get 2606:4700:4700::1111
docker compose exec tailscale tailscale netcheck
docker compose exec tailscale tailscale ping <他のノード>
```

WARP 停止時の確認: `docker compose stop warp` の状態で Exit Node 経由の通信がホスト回線へフォールバックせず失敗すること、`docker compose start warp` 後に復旧することを確認してください。

> **検証状況（2026-10-27）**: 経路分離のロジックは、ネットワーク名前空間上で `tailscaled` の `ip rule`（優先度 5210〜5270）を再現した試験で検証済みです（fwmark 付き IPv4 / IPv6 → 元ゲートウェイ、マークなし → WARP、再適用の冪等性、テーブル破損時の fail-closed、`verify-routing.sh` の全項目 PASS など 16 項目）。実際の Docker コンテナ上での動作確認は、試験環境の制約（レジストリからのイメージ取得不可、ブリッジネットワーク作成不可、cgroup の制約）により未実施です。通常の Docker ホストでの初回起動時に、上記の手順で確認してください。

## ファイル構成

| ファイル             | 説明                                                                                                             |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `docker-compose.yml` | WARP コンテナと Tailscale コンテナを定義。専用の Docker ネットワーク（`10.1.0.0/29` + `fd6a:204b:1e8d::/64`）で接続 |
| `entrypoint.sh`      | Tailscale コンテナの起動スクリプト。Auth Key のスマート処理、ルーティング書き換え、経路分離、NAT 設定、MSS Clamping を実行 |
| `verify-routing.sh`  | 経路分離が機能しているかを Tailscale コンテナ内で確認する検証スクリプト |
| `.env.example`       | 環境変数のテンプレート                                                                                           |

## アーキテクチャ

```

  Docker Network (10.1.0.0/29 / fd6a:204b:1e8d::/64) │
                                                     │
  ┌──────────────┐       ┌────────────────────┐      │
  │   Tailscale  │──────▶│   Cloudflare WARP  │──────┼──▶ Internet
  │  (Exit Node) │  NAT  │    (Gateway)       │      │
  │   10.1.0.3   │       │    10.1.0.2        │      │
  └──────────────┘       └────────────────────┘      │
        ▲                                            │
        │ Tailscale VPN
    クライアント
```

### コンテナの役割

- **WARP コンテナ** (`caomingjun/warp`): Cloudflare WARP トンネルを維持し、NAT ゲートウェイとして機能。`WARP_ENABLE_NAT=1` により NAT モードで動作
- **Tailscale コンテナ** (`tailscale/tailscale`): カーネルモードの TUN デバイスで VPN 終端として動作し、Exit Node を提供

### 通信の流れ

1. クライアントが Tailscale VPN 経由で Tailscale コンテナに接続
2. Tailscale コンテナが `iptables MASQUERADE` で送信元 IP を自身のアドレスに変換（NAT）
3. デフォルトゲートウェイを WARP コンテナ（`10.1.0.2`）に向けてパケットを転送
4. WARP コンテナが Cloudflare WARP トンネル経由でインターネットに送出

### 経路分離（`tailscaled` 自身の通信）

`main` テーブルのデフォルトを WARP へ向けると、そのままでは `tailscaled` 自身の通信（制御プレーン、DERP、direct 接続の確立・維持）まで WARP 経由になり、WARP の接続状態・遅延の影響を受けます。これを避けるため、`entrypoint.sh` はポリシールーティングで経路を分離します。

| 通信の種類                                | 識別方法              | 経路                                            |
| ---------------------------------------- | --------------------- | ----------------------------------------------- |
| `tailscaled` 自身の通信（IPv4 / IPv6）    | bypass fwmark 付き    | 元の Docker ゲートウェイ（通常回線）            |
| Exit Node として転送するインターネット通信 | マークなし            | WARP ゲートウェイ（`main` テーブルのデフォルト） |
| Tailnet 宛の通信                          | Tailscale のテーブル 52 | 従来どおり `tailscale0` 経由（変更なし）         |

仕組み:

1. 起動直後、デフォルトを WARP へ書き換える**前に**、元の Docker ゲートウェイを退避する
2. 退避したゲートウェイと接続済みサブネットを専用テーブル `100`（環境変数 `UNDERLAY_TABLE` で変更可）に保持する
3. `tailscaled` が自ソケットに付ける bypass fwmark（`0x80000/0xff0000`）を対象に、優先度 `5200` の `ip rule` で専用テーブルへ振り分ける。`tailscaled` 自身のルールは優先度 `5210` から始まるため、それより先に評価される
4. fwmark は起動時に `tailscaled` が導入したルールから自動検出する（取得できない場合は既定値を使用）。Tailscale のバージョンで値が変わった場合は `.env` の `TS_FWMARK` で上書きできる
5. 専用テーブルで解決できない fwmark 付きパケットは優先度 `5201` で `unreachable` とし、WARP へフォールバックさせない
6. WARP 障害時も `main` のデフォルトは WARP のままにし、Exit Node の転送通信が通常回線へ漏れないようにする（fail-closed）。一方、`tailscaled` 自身の通信は通常回線を使うため、接続維持・復旧処理は WARP の状態に依存しない

なお fwmark が付くのは `tailscaled` が発信するソケットのみです。コンテナ内のその他の通信（ウォッチドッグの `ping` 等）はマークなしとして扱われ、従来どおり WARP 経由で評価されます。

### 主要な技術的対策

| 対策                           | 詳細                                                                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| **NAT (Masquerade)**           | Tailscale コンテナから WARP コンテナへの通信で送信元 IP を書き換え、戻りパケットが正しくルーティングされるようにする |
| **MSS Clamping**               | VPN in VPN 構成のオーバーヘッドによるパケット詰まりを防ぐため、TCP MSS を 1120 に制限                                |
| **MTU 調整**                   | `TS_DEBUG_MTU=1280`（IPv6 最小 MTU）に設定し、パケット分断を回避                                                     |
| **遅延セットアップ**           | Tailscale 起動 10 秒後にルーティングを上書き（Tailscale が起動時にルーティングテーブルを書き換えるため）             |
| **Auth Key スマート処理**      | 既存の状態ファイルがある場合は `TS_AUTHKEY` を無視し、期限切れキーによる起動失敗を防止                               |
| **ネットワークウォッチドッグ** | WARP ゲートウェイへの疎通を 15 秒間隔で監視。復旧検知時にルート再適用と `tailscaled` への SIGHUP で即座に再接続      |
| **経路分離**                   | 元のゲートウェイを専用テーブル `100` に保持し、`tailscaled` の bypass fwmark（優先度 `5200` の `ip rule`）で通常回線へ振り分け。ウォッチドッグが分離の維持も毎周期確認し、崩れたら再適用 |
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

### 経路分離が機能していない

```bash
docker compose exec tailscale sh /verify-routing.sh
```

で FAIL 項目を確認してください。`tailscaled` が使う fwmark は `docker compose exec tailscale ip rule` の優先度 `5210` の行（`fwmark 0x80000/0xff0000 lookup main`）で確認できます。使用中の Tailscale のバージョンでこの値が既定と異なる場合は、`.env` に `TS_FWMARK=<確認した値>` を設定して再起動してください。
