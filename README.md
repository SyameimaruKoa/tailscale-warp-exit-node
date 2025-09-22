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
2. 必要があれば `.env` に `TS_AUTHKEY` と `WARP_REGISTER_TOKEN` を記述（セキュリティに注意）。
3. ビルド＆起動:

```bash
cd /opt/tails-warp
docker compose up -d --build
```

4. 自動登録が失敗する場合はコンテナに入って手動登録:

```bash
docker exec -it tails-warp bash
# inside
yes | warp-cli registration
warp-cli connect
tailscale up --authkey <your-key> --advertise-exit-node
```

---

## 5. 主要ファイル（抜粋）

* `docker-compose.yml`: コンテナを privileged で起動、ボリュームマウント、環境変数を指定
* `Dockerfile`: ubuntu:24.04 ベースに tailscale と cloudflare-warp をインストール
* `entrypoint.sh`:

  * warp-svc 起動
  * `yes | warp-cli registration` / `warp-cli connect`（自動化オプション）
  * IPv6 forwarding 即時有効化 (`sysctl -w net.ipv6.conf.all.forwarding=1` / `sysctl -w net.ipv6.conf.default.forwarding=1`)
  * tailscaled 起動
  * `tailscale up --advertise-exit-node`（`TS_HOSTNAME` が渡されていれば `--hostname "$TS_HOSTNAME"` を付与）
  * `iptables`/`ip6tables` による転送/NAT 設定
  * 監視ループ

---

## 6. 環境変数

* `TS_AUTHKEY` — Tailscale auth key。あると自動で `tailscale up` を実行します。
* `WARP_REGISTER_TOKEN` — Cloudflare が発行する自動登録用トークン（ある場合のみ自動で `yes | warp-cli registration` が実行されます）
* `TS_HOSTNAME` — （任意）Tailscale 上で表示されるデバイス名（ホスト名）を指定できます。設定するとエントリポイントは `tailscale up --advertise-exit-node --hostname "$TS_HOSTNAME"` のように起動します。

> 注: 自動化トークンを使用する場合は、トークンの取り扱いに注意してください（.env を Git 管理しない等）。

---

## 7. テスト方法

1. Android の Tailscale アプリで該当ノードを Exit Node に切り替える。
2. IPv4 テスト:

```bash
curl -4 https://ifconfig.co
```

3. IPv6 テスト:

```bash
curl -6 https://ifconfig.co
```

4. コンテナ内での確認:

```bash
ip -6 addr show
ip -6 route
ip -6 route get 2606:4700:4700::1111
ip6tables -t nat -L -n -v
tailscale status --json
warp-cli status
```

5. パケット確認（必要なら）:

```bash
tcpdump -n -i tailscale0 ip6 -c 50
tcpdump -n -i <WARP_IF> ip6 -c 50
```

---

## 8. IPv6 関連の注意点

* **IPv6 フォワーディングを有効化**する必要があります。
  エントリポイントで以下を即時実行しています：

  ```bash
  sysctl -w net.ipv6.conf.all.forwarding=1
  sysctl -w net.ipv6.conf.default.forwarding=1
  ```
* `ip6tables` の `nat` テーブル（MASQUERADE）を使うにはカーネルモジュールが必要（`ip6table_nat` 等）。
* WARP 側に IPv6 アドレスが割り当てられていること（`ip -6 addr show <WARP_IF>`）を確認すること。
* NAT が使えない環境ではルーティング（NDP/プレフィックスルーティング）での対応が必要になり複雑化します。

---

## 9. 永続化（sysctl / ip6tables）

* `sysctl` を永続化する場合は `/etc/sysctl.d/99-tails-warp.conf` を作成して `sysctl --system` を実行。
* `ip6tables` のルールは `ip6tables-persistent` (`netfilter-persistent`) を使って保存すると便利。もしくはコンテナのエントリポイントで起動時にルールを復元する。

---

## 10. トラブルシュート（よくある事象）

* **IPv4 は通るが IPv6 は通らない**

  * `net.ipv6.conf.all.forwarding` が 0 → 1 にする
  * `ip6tables -t nat` が利用できない → カーネルモジュール確認 / ホストで対応
  * WARP に IPv6 アドレスが割り当てられていない

* **warp-cli が Terms を要求する**

  * 初回は `warp-cli` が利用規約同意を要求するのでコンテナ内で `warp-cli` を実行して同意させる必要がある

* **Tailscale 警告：IPv6 forwarding is disabled**

  * sysctl の IPv6 forwarding を設定後、`tailscale down && tailscale up` を実施して警告が消えるか確認する

* **DNS 問題**

  * WARP が DNS を上書きするため、必要に応じて `warp-cli` の設定やコンテナ内の `resolv.conf` を調整する

---

## 11. セキュリティ注意

* `privileged` コンテナはホストに高い影響を与えられる。プロダクションではネットワーク分離や最小権限、監視を検討すること。
* 認証トークン（Tailscale / WARP）は安全に保存し、公開しないこと。

---

## 12. 要求されたときに貼ってほしい出力（サポート用）

問題発生時に以下を貼ると早く解決できます:

```
ip -6 addr show
ip -6 route
ip -6 route get 2606:4700:4700::1111
ip6tables -t nat -L -n -v
ip6tables -L -n -v
tailscale status --json
warp-cli status
```
