#!/bin/sh
# 経路分離の検証スクリプト (Issue #1 の受け入れ条件確認用)
# ヘルプは下の show_help() に実装している (-h / --help で表示)

show_help() {
    cat <<'EOF'
Usage: verify-routing.sh [-h|--help]

Tailscaleコンテナ内で実行し、経路分離が機能しているかを確認します。

  確認内容:
    1. fwmark付き (tailscaled自身) の経路が元のDockerゲートウェイを向くこと (IPv4/IPv6)
    2. マークなし (Exit Node転送) の経路がWARPゲートウェイを向くこと (IPv4/IPv6)
    3. 専用テーブルと ip rule (優先度・unreachableガード) が存在すること

  実行方法 (ホスト側から):
    docker compose exec tailscale sh /verify-routing.sh

  環境変数 (entrypoint.sh と同じ意味・同じ既定値):
    WARP_GW         WARPのIPv4ゲートウェイ (既定: 10.1.0.2)
    WARP_GW6        WARPのIPv6ゲートウェイ (既定: fd6a:204b:1e8d::2)
    TS_FWMARK       tailscaledの bypass fwmark (未指定時は ip rule から検出、
                    検出できなければ 0x80000/0xff0000)
    UNDERLAY_TABLE  経路分離用のテーブル番号 (既定: 100)
    UNDERLAY_PRIO   fwmarkルールの優先度 (既定: 5200)

  終了コード: 0 = 全項目PASS / 1 = FAILあり / 2 = 引数エラー
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        ;;
    *)
        echo "ERROR: Unknown argument: $1" >&2
        show_help >&2
        exit 2
        ;;
esac

WARP_GW="${WARP_GW:-10.1.0.2}"
WARP_GW6="${WARP_GW6:-fd6a:204b:1e8d::2}"
UNDERLAY_TABLE="${UNDERLAY_TABLE:-100}"
UNDERLAY_PRIO="${UNDERLAY_PRIO:-5200}"

if [ -n "${TS_FWMARK:-}" ]; then
    MARK="$TS_FWMARK"
else
    MARK=$(ip rule show 2>/dev/null | awk '/fwmark/ && /lookup main/ {for(i=1;i<=NF;i++) if($i=="fwmark") {print $(i+1); exit}}')
    if [ -z "$MARK" ]; then
        MARK=$(ip -6 rule show 2>/dev/null | awk '/fwmark/ && /lookup main/ {for(i=1;i<=NF;i++) if($i=="fwmark") {print $(i+1); exit}}')
    fi
    if [ -z "$MARK" ]; then
        MARK="0x80000/0xff0000"
    fi
fi
MARK_VALUE="${MARK%%/*}"

FAILURES=0

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

# $1: 説明 / $2: 実際の経路検索結果 / $3: 期待するゲートウェイ
check_route() {
    case "$2" in
        *"$3"*)
            pass "$1 (via $3)"
            ;;
        *)
            fail "$1 (expected via $3, got: ${2:-no route})"
            ;;
    esac
}

ORIG_GW=$(ip route show table "$UNDERLAY_TABLE" default 2>/dev/null | awk '{print $3}' | head -1)
ORIG_GW6=$(ip -6 route show table "$UNDERLAY_TABLE" default 2>/dev/null | awk '{print $3}' | head -1)

echo "== ip rule (IPv4) =="
ip rule show
echo "== ip rule (IPv6) =="
ip -6 rule show
echo "== Underlay table $UNDERLAY_TABLE =="
ip route show table "$UNDERLAY_TABLE" 2>/dev/null || true
ip -6 route show table "$UNDERLAY_TABLE" 2>/dev/null || true
echo "== Checks (fwmark=$MARK, table=$UNDERLAY_TABLE, prio=$UNDERLAY_PRIO) =="

if ip rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*fwmark ${MARK}.*lookup ${UNDERLAY_TABLE}"; then
    pass "IPv4 fwmarkルールが存在する"
else
    fail "IPv4 fwmarkルールが存在しない"
fi
if ip -6 rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*fwmark ${MARK}.*lookup ${UNDERLAY_TABLE}"; then
    pass "IPv6 fwmarkルールが存在する"
else
    fail "IPv6 fwmarkルールが存在しない"
fi

if [ -n "$ORIG_GW" ]; then
    check_route "IPv4 tailscaled自身の通信は通常回線へ" "$(ip route get 1.1.1.1 mark "$MARK_VALUE" 2>/dev/null | head -1)" "$ORIG_GW"
else
    fail "専用テーブルにIPv4デフォルトルートがない"
fi
check_route "IPv4 マークなし通信はWARPへ" "$(ip route get 1.1.1.1 2>/dev/null | head -1)" "$WARP_GW"

if [ -n "$ORIG_GW6" ]; then
    check_route "IPv6 tailscaled自身の通信は通常回線へ" "$(ip -6 route get 2606:4700:4700::1111 mark "$MARK_VALUE" 2>/dev/null | head -1)" "$ORIG_GW6"
else
    fail "専用テーブルにIPv6デフォルトルートがない"
fi
check_route "IPv6 マークなし通信はWARPへ" "$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -1)" "$WARP_GW6"

echo "== Result =="
if [ "$FAILURES" -eq 0 ]; then
    echo "OK: 経路分離は機能しています。"
    echo "注意: Exit Nodeクライアントから見た出口IPがWARP側であること、"
    echo "      WARP停止時に転送通信が通常回線へ漏れないことは、実機で"
    echo "      クライアント側から別途確認してください (README参照)。"
    exit 0
else
    echo "NG: ${FAILURES}件の確認に失敗しました。"
    exit 1
fi
