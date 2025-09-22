# README — Tailscale Exit Node inside Docker using Cloudflare WARP

> このリポジトリは **Docker コンテナ内で Tailscale の Exit Node を動作させ、出口を Cloudflare WARP（IPv4/IPv6）にする** 構成をまとめたものです。
>
> **重要**: コンテナは `privileged` または十分な `CAP_NET_ADMIN` 権限と `/dev/net/tun` を必要とします。WARP-in-container はホスト上で動かすより脆弱になり得ます。セキュリティと安定性を理解した上で利用してください。

---

## 目次

1. 概要
2. 前提条件
3. ファイル構成
4. セットアップ（ビルド・起動）
5. 主要ファイル（抜粋）
6. 環境変数
7. テスト方法
8. IPv6 関連の注意点
9. 永続化（sysctl / ip6tables）
10. トラブルシュート
11. セキュリティ注意
12. 参考（操作出力を共有するための一覧）

---

## 1. 概要

この構成は、Ubuntu Server 24.04 ホスト上で Docker を使い、1 つのコンテナ内で `tailscaled` と `warp-svc`（Cloudflare WARP クライアント）を起動して、Tailscale の Exit Node を提供します。Tailscale クライアント（Android 等）はこの Exit Node を選択することで、通信が Cloudflare WARP 経由でインターネットへ出ます（IPv4 / IPv6）。

---

## 2. 前提条件

* Ubuntu Server 24.04（ホスト）
* Docker + Docker Compose v2
* root 権限（または sudo）
* Tailscale の認証キー（`TS_AUTHKEY`）または手動での `tailscale up` 認証が可能
* Cloudflare WARP の登録情報（`WARP_REGISTER_TOKEN` があると自動化しやすいが、無くても手動登録可）
* コンテナは `privileged` または `CAP_NET_ADMIN` と `/dev/net/tun` を提供

---

## 3. ファイル構成（例）

```
/opt/tails-warp/
├─ docker-compose.yml
└─ tails-warp/
   ├─ Dockerfile
   └─ entrypoint.sh
```

---

## 4. セットアップ（ビルド・起動）

1. リポジトリルート（例: `/opt/tails-warp`）に上記ファイルを置く。
2. 必要があれば `.env` に `TS_AUTHKEY` 、 `TS_HOSTNAME` と `WARP_REGISTER_TOKEN` を記述（セキュリティに注意）。
3. ビルド＆起動:

```bash
cd /opt/tails-warp
docker compose up -d --build
```

4. 自動登録が失敗する場合はコンテナに入って手動登録:

```bash
docker exec -it tails-warp bash
# inside
yes | warp-cli registration    # Cloudflare の指示に従う
warp-cli connect
tailscale up --authkey <your-key> --advertise-exit-node --hostname=<device name>
```

---

## 5. 主要ファイル（抜粋）

* `docker-compose.yml`: コンテナを privileged で起動、ボリュームマウント、環境変数を指定
* `Dockerfile`: ubuntu:24.04 ベースに tailscale と cloudflare-warp をインストール
* `entrypoint.sh`: warp-svc 起動 → `yes | warp-cli registration`/`warp-cli connect`（自動化オプション）→ tailscaled 起動 → `tailscale up --advertise-exit-node`（`TS_HOSTNAME` が渡されていれば `--hostname "$TS_HOSTNAME"` を付与）→ `sysctl` と `iptables`/`ip6tables` による転送/NAT 設定 → 監視ループ

