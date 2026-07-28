#!/bin/bash
set -e

show_help() {
    echo "Usage: ./setup.sh [OPTIONS]"
    echo ""
    echo "Tailscale + WARP Exit Node - ネットワーク自動検出・.env生成スクリプト"
    echo ""
    echo "Options:"
    echo "  -h, --help    このヘルプメッセージを表示して終了します。"
    echo ""
    echo "説明:"
    echo "  現在のLinuxホストのデフォルトルートから、物理インターフェース名、"
    echo "  DHCPゲートウェイ、サブネット情報を自動検出して .env ファイルを生成します。"
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

echo "============================================================"
echo " Tailscale + WARP Exit Node - 物理ネットワーク自動検出"
echo "============================================================"

# デフォルトインターフェースとゲートウェイの自動検出
PARENT_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
GATEWAY_IP=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')

if [ -z "$PARENT_IF" ] || [ -z "$GATEWAY_IP" ]; then
    echo "ERROR: デフォルトルートが見つかりませんでした。ネットワーク接続を確認してください。"
    exit 1
fi

SUBNET_CIDR=$(ip route show dev "$PARENT_IF" 2>/dev/null | grep '/' | awk '{print $1; exit}')

if [ -z "$SUBNET_CIDR" ]; then
    echo "ERROR: インターフェース $PARENT_IF のサブネットが検出できませんでした。"
    exit 1
fi

echo "検出されたネットワーク環境:"
echo "  - 物理インターフェース (MACVLAN_PARENT): $PARENT_IF"
echo "  - 物理ゲートウェイ       (MACVLAN_GATEWAY): $GATEWAY_IP"
echo "  - 物理サブネット         (MACVLAN_SUBNET) : $SUBNET_CIDR"
echo ""

# .env ファイルの更新/作成
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example "$ENV_FILE"
        echo ".env.example から .env を作成しました。"
    else
        touch "$ENV_FILE"
    fi
fi

# 検出したパラメータを .env に反映
sed -i '/^MACVLAN_PARENT=/d' "$ENV_FILE"
sed -i '/^MACVLAN_SUBNET=/d' "$ENV_FILE"
sed -i '/^MACVLAN_GATEWAY=/d' "$ENV_FILE"

echo "MACVLAN_PARENT=$PARENT_IF" >> "$ENV_FILE"
echo "MACVLAN_SUBNET=$SUBNET_CIDR" >> "$ENV_FILE"
echo "MACVLAN_GATEWAY=$GATEWAY_IP" >> "$ENV_FILE"

echo "============================================================"
echo " .env ファイルの更新が完了しました！"
echo " 次のコマンドでコンテナを起動できます:"
echo "   docker compose up -d"
echo "============================================================"
