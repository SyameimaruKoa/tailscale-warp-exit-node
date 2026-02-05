# Tailscale Exit Node with Cloudflare WARP (Docker Compose)

> **「自宅のIPを晒したくない」「IPv4環境だけどIPv6サイトに繋ぎたい」「高速で安定したモバイルVPNが欲しい」**
>
> そんなワガママな願いを叶えるための、最強のExit Node構成じゃ。感謝するのじゃな！

このリポジトリは、**Docker Compose** を用いて **Cloudflare WARP** と **Tailscale** を連携させ、高速かつセキュアな Exit Node を構築するためのプロジェクトじゃ。

過去の「全部入り巨大コンテナ」による不安定な構成を捨て、役割を分離したマイクロサービスアーキテクチャを採用しておる。

## ✨ 特徴

- **🔒 高い匿名性** : インターネットへの出口は Cloudflare WARP になるため、自宅のプロバイダ(ISP)のIPアドレスが隠蔽される。
- **🚀 高速通信** : カーネルモード（TUN）と適切な NAT/MSS Clamping 設定により、200Mbps超の高速通信を実現（環境による）。
- **🌐 IPv6 対応** : ホストマシンが IPv4 しか使えなくても、WARP トンネルを経由して IPv6 インターネットへアクセス可能。
- **🛡️ 安定性** : `iptables` による強制 NAT とルーティング制御により、パケットの迷子（Martian packets）を防ぎ、安定した接続を維持する。
- **軽量** : 既存の最適化された Docker イメージ（`caomingjun/warp` + 公式 `tailscale`）を組み合わせるため、ビルド不要で軽量じゃ。

## ⚙️ 前提条件

この構成を動かすには、以下の準備が必要じゃ。怠るでないぞ。

- **Docker & Docker Compose** : インストール済みであること。
- **Tailscale Auth Key** : `tskey-auth-...` から始まる認証キー。
- **【重要】ホストOS側のカーネルモジュール** :
  IPv6 の NAT を機能させるため、**ホストOS（Ubuntu等）** で以下のモジュールが有効になっている必要がある。

```bash
# 必ずホスト側で実行せよ！
sudo modprobe ip6table_nat
sudo modprobe iptable_nat
```

※ 再起動後も有効になるよう、`/etc/modules` に追記することを推奨するぞ。

## 🚀 使い方

### 1. リポジトリのクローン

このリポジトリを手元に持ってくるのじゃ。

```bash
git clone https://github.com/SyameimaruKoa/tailscale-warp-exit-node.git
cd tailscale-warp-exit-node
```

### 2. 設定ファイル (`.env`) の作成

`.env` ファイルを作成し、Tailscale の認証キーを記述せよ。

ホスト名は自動的にホストマシンのものが使われるが、変えたい場合は `TS_HOSTNAME` も書くがよい。

```.env
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxxxxxxx
# TS_HOSTNAME=warp-my-server  # 省略するとホストのホスト名になる
```

### 3. 起動

Docker Compose でコンテナを立ち上げる。

```bash
docker compose up -d
```

### 4. 接続確認

Tailscale の管理画面で新しいノード（例: `warp-ubuntu`）が表示され、**「Exit Node」** として認識されているか確認せよ。

スマホなどのクライアントでこの Exit Node を有効にし、[test-ipv6.com](https://test-ipv6.com/index.html.ja_JP) などにアクセスして以下を確認するのじゃ。

1. **IPv4** : Cloudflare の IP になっているか？
2. **IPv6** : Cloudflare のアドレスが検出されるか？
3. **速度** : 動画などがスムーズに見れるか？

## 📂 ファイル構成と役割

| **ファイル**         | **説明**                                                                                                                           |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `docker-compose.yml` | 全体の構成定義。WARPコンテナとTailscaleコンテナを定義し、専用の内部ネットワークで接続しておる。                                    |
| `entrypoint.sh`      | Tailscale コンテナの起動スクリプト。ルーティングの書き換え、NAT設定、MTU調整（MSS Clamping）を**遅延実行**で行う重要な役割を持つ。 |

## 🧠 仕組み（アーキテクチャ）

なぜこれが「最強」なのか、少しだけ解説してやろう。

### 1. コンテナの分離 (Sidecar / Bridge)

以前の「1つのコンテナに全部詰め込む」方式はやめじゃ。

- **WARPコンテナ** : SOCKS5プロキシやGatewayとして機能し、Cloudflareへのトンネルを維持する。
- **Tailscaleコンテナ** : VPNの終端装置として機能する。

この2つを Docker の内部ネットワーク（`172.25.0.0/16`）で接続し、明確な役割分担をしておる。

### 2. 強制NAT (Masquerade)

Tailscale から WARP へパケットを送る際、送信元 IP が「スマホの VPN IP」のままだと、WARP は返信先が分からずパケットを捨ててしまう。

そこで `iptables -j MASQUERADE` を使い、**「Tailscale コンテナからの通信である」と送信元を偽装（NAT）** することで、正常に返信が戻ってくるようにしておる。

### 3. MSS Clamping による最適化

VPN の中に VPN を通す（Tailscale in WARP）構成では、ヘッダのオーバーヘッドによりパケットサイズ（MTU）が制限を超え、通信が詰まることがある。

そこで `TCPMSS --set-mss 1120` を適用し、**パケットサイズを強制的に小さく調整** することで、動画のバッファリングや接続切れを根絶したのじゃ。

### 4. 時間差攻撃（Delayed Setup）

Tailscale は起動時にルーティングテーブルを自分の好きなように書き換えてしまう。

そのため、`entrypoint.sh` 内で **「Tailscale が起動しきった 10秒後」** を狙って、WARP 向けのルーティング設定を強制的に上書き（Overwrite）しておる。これが安定動作のキモじゃ。

## ⚠️ トラブルシューティング

- **Q. Tailscale のログに `IPv6 NAT failed` と出る**
  - **A.** ホストOS側で `sudo modprobe ip6table_nat` を実行していないのが原因じゃ。必ず実行せよ。
- **Q. 接続はできるがインターネットに出られない**
  - **A.** `docker logs tailscale` を確認せよ。`Background: Setup COMPLETE.` が表示されているか？ エラーが出ていないか確認するのじゃ。
- **Q. 速度が遅い**
  - **A.** おそらく MTU の問題じゃ。`entrypoint.sh` 内の `TCPMSS` の値を調整（例: 1120 -> 1100）してみると改善するかもしれぬ。

## 📜 ライセンス

好きに使うがよい。ただし、自己責任じゃぞ？

わっちは知らぬからな！
