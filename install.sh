#!/bin/bash
#
# install.sh — update-zt-moon-dynamic-ipv6 一键安装脚本
#
# 用法:
#   curl -sSL https://raw.githubusercontent.com/sch-chun/update-zt-moon-dynamic-ipv6/main/install.sh | sudo bash
#
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- 检查 root ----------
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此脚本（sudo）"
    exit 1
fi

info "=============================="
info " update-zt-moon-dynamic-ipv6"
info " 一键安装脚本"
info "=============================="
echo ""

# ---------- 检查依赖 ----------
info "检查系统依赖..."

if ! command -v jq &> /dev/null; then
    warn "未安装 jq，正在自动安装..."
    if command -v apt &> /dev/null; then
        apt update -qq && apt install -y -qq jq
    elif command -v yum &> /dev/null; then
        yum install -y jq
    elif command -v dnf &> /dev/null; then
        dnf install -y jq
    else
        err "找不到 apt/yum/dnf 包管理器，请手动安装 jq"
        exit 1
    fi
    ok "jq 安装完成"
else
    ok "jq 已安装"
fi

if ! command -v zerotier-idtool &> /dev/null; then
    err "未找到 zerotier-idtool，请先安装 ZeroTier"
    err "参考：curl -s https://install.zerotier.com | sudo bash"
    exit 1
fi

# ---------- 下载主脚本 ----------
SCRIPT_URL="https://raw.githubusercontent.com/sch-chun/update-zt-moon-dynamic-ipv6/main/update-zt-moon-ipv6.sh"
SCRIPT_DEST="/usr/local/bin/update-zt-moon-ipv6.sh"

echo ""
info "下载主脚本..."

TMP_SCRIPT=$(mktemp)
if curl -sSL "$SCRIPT_URL" -o "$TMP_SCRIPT"; then
    chmod +x "$TMP_SCRIPT"
    mv "$TMP_SCRIPT" "$SCRIPT_DEST"
    ok "主脚本已部署到 $SCRIPT_DEST"
else
    rm -f "$TMP_SCRIPT"
    err "下载失败，请检查网络连接"
    exit 1
fi

# ---------- 交互式配置 ----------
echo ""
info "开始配置脚本参数..."

# 显示当前 IPv6 地址列表
echo ""
echo "当前系统的全局 IPv6 地址列表："
ip -6 addr show scope global up | grep -Po 'inet6\s+\K[0-9a-f:]+(?=/)' | cat -n
echo ""

# 配置 IPv6 索引
DEFAULT_INDEX=9
read -r -p "请选择使用第几个 IPv6 地址（默认: $DEFAULT_INDEX）: " IPV6_INDEX
IPV6_INDEX="${IPV6_INDEX:-$DEFAULT_INDEX}"
info "将使用第 $IPV6_INDEX 个全局 IPv6 地址"

# 配置邮件通知
DEFAULT_ENABLE="Y"
read -r -p "是否启用邮件通知？(Y/n，默认: $DEFAULT_ENABLE): " ENABLE_INPUT
ENABLE_INPUT="${ENABLE_INPUT:-$DEFAULT_ENABLE}"
if [[ "$ENABLE_INPUT" =~ ^[Yy]$ ]]; then
    read -r -p "请输入接收通知的邮箱地址: " MAIL_TO
    if [[ -z "$MAIL_TO" ]]; then
        warn "未输入邮箱地址，邮件通知将保持禁用"
        ENABLE_EMAIL="false"
    else
        ENABLE_EMAIL="true"
        info "邮件通知已启用，通知将发送至: $MAIL_TO"
        # 配置发件邮箱
        DEFAULT_FROM="root@$(hostname -f 2>/dev/null || hostname)"
        read -r -p "请输入发件邮箱地址（默认: ${DEFAULT_FROM}）: " MAIL_FROM
        MAIL_FROM="${MAIL_FROM:-${DEFAULT_FROM}}"
        info "发件邮箱设置为: $MAIL_FROM"
    fi
else
    ENABLE_EMAIL="false"
    info "邮件通知已禁用"
fi

# ---------- 写入配置 ----------
info "应用配置到脚本..."
sed -i "s/^IPV6_INDEX=.*/IPV6_INDEX=${IPV6_INDEX}/" "$SCRIPT_DEST"
sed -i "s/^ENABLE_EMAIL=.*/ENABLE_EMAIL=${ENABLE_EMAIL}/" "$SCRIPT_DEST"
if [[ "$ENABLE_EMAIL" == "true" ]] && [[ -n "${MAIL_TO:-}" ]]; then
    sed -i "s|^MAIL_TO=.*|MAIL_TO=\"${MAIL_TO}\"|" "$SCRIPT_DEST"
    sed -i "s|^MAIL_FROM=.*|MAIL_FROM=\"${MAIL_FROM}\"|" "$SCRIPT_DEST"
fi
ok "配置已应用"

# ---------- 设置定时任务 ----------
echo ""
info "设置定时任务（每小时执行一次）..."
CRON_JOB="0 * * * * ${SCRIPT_DEST}"

# 检查是否已存在相同的定时任务
if crontab -l 2>/dev/null | grep -Fq "$SCRIPT_DEST"; then
    warn "定时任务已跳过"
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    ok "定时任务已添加：每小时执行一次 $SCRIPT_DEST"
fi

# ---------- 首次执行 ----------
echo ""
info "首次执行：检查并更新 Moon 配置..."
if bash "$SCRIPT_DEST"; then
    ok "首次执行成功！"
else
    warn "首次执行未完全成功，请检查脚本输出"
fi

# ---------- 完成 ----------
echo ""
info "=============================="
info "安装完成！"
info "=============================="
echo ""
echo "主脚本路径: $SCRIPT_DEST"
echo "定时任务:   每小时自动执行一次"
echo ""
echo "手动运行:   sudo ${SCRIPT_DEST}"
echo "查看日志:   sudo ${SCRIPT_DEST} 直接运行即可查看输出"
echo ""
if [[ "$ENABLE_EMAIL" == "true" ]]; then
    echo "邮件通知:   已启用（发送至 $MAIL_TO，发件人: $MAIL_FROM）"
fi
