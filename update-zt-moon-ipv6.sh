#!/bin/bash
#
# update-zt-moon-ipv6.sh
# 读取已有的 moon.json，替换 stableEndpoints 中的 IPv6 地址，重新生成 .moon
# 适用于 Debian / Ubuntu 系统
#

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------- 配置 ----------

ZT_HOME="/var/lib/zerotier-one"
MOON_JSON="${ZT_HOME}/moon.json"
MOONS_DIR="${ZT_HOME}/moons.d"
IPV6_CACHE="/var/cache/zt-moon-ipv6.txt"
ZT_PORT="9993"
SERVICE_NAME="zerotier-one"

# 指定网卡名，留空表示不限制
INTERFACE="enp2s0"

# 要匹配的 IPv6 地址标记，如 mngtmpaddr、dynamic、temporary 等，留空表示不限制
ADDR_FLAG="mngtmpaddr"

# 在匹配结果中取第几个地址（从1开始，默认为1）
IPV6_INDEX=1

# --- 邮件通知配置 ---
ENABLE_EMAIL=true                   # 改为 false 可禁用邮件通知
MAIL_FROM=""
MAIL_TO=""        # 接收通知的邮箱
MAIL_SUBJECT="ZeroTier Moon IPv6 已更新"

# ---------- 函数：获取 IPv6 ----------

get_global_ipv6() {
    local index="${1:-1}"
    local dev_flag=""
    local grep_flag=""
    [[ -n "$INTERFACE" ]] && dev_flag="dev $INTERFACE"
    
    # 构建 ip 命令，只显示全局且已启用的地址
    local ip_cmd="ip -6 addr show scope global up $dev_flag"
    
    # 如果不限制标记，则直接提取地址；否则先 grep 行，再提取
    if [[ -n "$ADDR_FLAG" ]]; then
        $ip_cmd | grep -w "$ADDR_FLAG" | grep -Po 'inet6\s+\K[0-9a-f:]+(?=/)' \
            | awk -v n="$index" 'NR==n {print; exit}'
    else
        $ip_cmd | grep -Po 'inet6\s+\K[0-9a-f:]+(?=/)' \
            | awk -v n="$index" 'NR==n {print; exit}'
    fi
}

# ---------- 检查 root ----------

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行此脚本。" >&2
    exit 1
fi

# ---------- 检查依赖 ----------

if ! command -v zerotier-idtool &> /dev/null; then
    echo "未找到 zerotier-idtool，请确认 ZeroTier 已安装。" >&2
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "需要 jq 工具来修改 JSON，请先安装：sudo apt install jq" >&2
    exit 1
fi

# ---------- 检查 moon.json 是否存在 ----------

if [[ ! -f "$MOON_JSON" ]]; then
    echo "未找到 Moon 配置文件：$MOON_JSON" >&2
    exit 1
fi

# ---------- 获取当前 IPv6 ----------

CURRENT_IPV6=$(get_global_ipv6 "$IPV6_INDEX")
if [[ -z "$CURRENT_IPV6" ]]; then
    echo "未检测到第 ${IPV6_INDEX} 个全局 IPv6 地址，请检查网络配置或调整 IPV6_INDEX。" >&2
    exit 1
fi
echo "当前选择第 ${IPV6_INDEX} 个全局 IPv6: $CURRENT_IPV6"

# ---------- 与缓存比较 ----------

if [[ -f "$IPV6_CACHE" ]] && [[ "$(cat $IPV6_CACHE)" == "$CURRENT_IPV6" ]]; then
    echo "IPv6 地址未变化，无需更新。"
    exit 0
fi

# ---------- 更新 moon.json 中的 stableEndpoints ----------

echo "正在更新 ${MOON_JSON} 中的 IPv6 地址..."
TEMP_JSON=$(mktemp /tmp/moon_updated.XXXXXX)

jq --arg endpoint "${CURRENT_IPV6}/${ZT_PORT}" \
   '.roots[0].stableEndpoints = [ $endpoint ]' \
   "$MOON_JSON" > "$TEMP_JSON"

# ---------- 重新生成 .moon 文件 ----------

echo "正在生成新的 .moon 文件..."
zerotier-idtool genmoon "$TEMP_JSON"
rm -f "$TEMP_JSON"

# 查找生成的文件（支持新版带前缀的命名）
MOON_ID=$(jq -r '.id' "$MOON_JSON")
NEW_MOON=$(find . -maxdepth 1 -name "*${MOON_ID}.moon" -print -quit 2>/dev/null)
if [[ -z "$NEW_MOON" ]]; then
    NEW_MOON=$(find "$ZT_HOME" -maxdepth 1 -name "*${MOON_ID}.moon" -print -quit 2>/dev/null)
fi

if [[ ! -f "$NEW_MOON" ]]; then
    echo "生成 .moon 文件失败，找不到包含 ${MOON_ID} 的 .moon 文件。" >&2
    exit 1
fi

echo "找到生成的 Moon 文件：$NEW_MOON"

# ---------- 部署到 moons.d ----------

mkdir -p "$MOONS_DIR"

# 删除旧的相关文件
rm -f "${MOONS_DIR}/"*"${MOON_ID}.moon"
cp "$NEW_MOON" "${MOONS_DIR}/"
rm -f "$NEW_MOON"
echo "已将新的 .moon 文件放入 ${MOONS_DIR}/"

# ---------- 重启 ZeroTier ----------

echo "重启 ${SERVICE_NAME} 服务..."
systemctl restart "$SERVICE_NAME"

# ---------- 写入缓存 ----------

mkdir -p "$(dirname "$IPV6_CACHE")"
echo "$CURRENT_IPV6" > "$IPV6_CACHE"

echo "Moon 节点 IPv6 更新完成（第 ${IPV6_INDEX} 个地址）。"

# ---------- 发送邮件通知 ----------

if [[ "$ENABLE_EMAIL" == "true" ]]; then
    if command -v sendmail &> /dev/null; then
        HOSTNAME=$(hostname -f 2>/dev/null || hostname)

        # 生成邮件内容
        MAIL_BODY=$(cat <<EOF
From: ZeroTier Moon <$MAIL_FROM>
To: $MAIL_TO
Subject: $MAIL_SUBJECT

ZeroTier Moon 节点 ($HOSTNAME) 的 IPv6 端点已自动更新。

Moon ID: $MOON_ID
新 IPv6 地址: ${CURRENT_IPV6}/${ZT_PORT}
更新时间: $(date)

所有客户端需要重新执行 orbit 以获取最新端点：
  zerotier-cli deorbit $MOON_ID
  zerotier-cli orbit $MOON_ID $MOON_ID

—— Moon 自动更新脚本
EOF
)

        echo "$MAIL_BODY" | sendmail -f "$MAIL_FROM" "$MAIL_TO"
        STATUS=$?
        if [[ $STATUS -eq 0 ]]; then
            echo "已发送更新通知邮件至 $MAIL_TO"
        else
            echo "邮件发送失败，sendmail 退出码: $STATUS" >&2
        fi
    else
        echo "未找到 sendmail 命令，无法发送邮件通知。" >&2
    fi
fi
