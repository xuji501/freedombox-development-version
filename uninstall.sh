#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# FreedomBox 定制版 · 整体回退
#
# 按部署的相反顺序调用各子项目的 rollback.sh，把机器恢复到部署前。
# 每个子项目自己会找 /root/freedombox-*-backup/ 下最新的一份备份。
#
# 用法：
#   sudo bash uninstall.sh                # 交互确认后全部回退
#   sudo bash uninstall.sh --yes          # 不确认
#   sudo bash uninstall.sh --only=fixes,branding
#   sudo bash uninstall.sh --dry-run

set -uo pipefail

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$BUNDLE_DIR/lib/common.sh"

ASSUME_YES=0
DRY_RUN=0
ONLY=""

# 回退顺序与部署顺序相反：后装的东西先撤。
# base（freedombox 本体）刻意不在列表里：卸掉它等于毁掉整台机器，只提示不执行。
STEP_IDS=(firstboot fixes branding openvpn gre routes ipv6 dhcp)

step_dir() {
    case "$1" in
        base)     echo "00-base" ;;
        dhcp)     echo "10-dhcp" ;;
        ipv6)     echo "20-ipv6" ;;
        routes)   echo "30-routes" ;;
        gre)      echo "35-gre" ;;
        openvpn)  echo "40-openvpn" ;;
        branding) echo "50-branding" ;;
        fixes)    echo "60-fixes" ;;
        firstboot) echo "90-firstboot" ;;
    esac
}

step_title() {
    case "$1" in
        base)     echo "FreedomBox 本体（离线安装）" ;;
        dhcp)     echo "DHCP 服务器模块" ;;
        ipv6)     echo "IPv6 路由器模块" ;;
        routes)   echo "路由管理模块（静态路由 + OSPF）" ;;
        gre)      echo "GRE 隧道模块" ;;
        openvpn)  echo "OpenVPN 账号管理" ;;
        branding) echo "全站页脚版权信息" ;;
        fixes)    echo "Plinth 404 修复" ;;
        firstboot) echo "首次启动向导自动化" ;;
    esac
}

usage() {
    cat <<'USAGE'
FreedomBox 定制版 · 整体回退

用法：
  sudo bash uninstall.sh [选项]

选项：
  -y, --yes             不询问，直接回退
      --dry-run         只列出将执行的动作
      --only=ID[,ID...] 只回退指定步骤
                        （firstboot fixes branding openvpn gre routes ipv6 dhcp）
  -h, --help            显示本帮助

注意：base 步骤（freedombox 本体）不支持回退，本脚本不会卸载 freedombox。
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --only=*)  ONLY="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *)         err "未知参数：$1"; usage; exit 2 ;;
    esac
    shift
done

in_list() {
    local needle=$1 list=$2 item
    [ -z "$list" ] && return 1
    local IFS=,
    for item in $list; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

selected() {
    [ -n "$ONLY" ] || return 0
    in_list "$1" "$ONLY"
}

require_root

STAMP=$(date +%Y%m%d-%H%M%S)
# common.sh 已经把 LOG_FILE 默认成 /dev/null，这里必须直接赋值而不是用 :- 兜底。
LOG_FILE="/var/log/freedombox-custom-uninstall-$STAMP.log"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/freedombox-custom-uninstall-$STAMP.log"

banner "FreedomBox 定制版 · 整体回退"
info "日志文件：$LOG_FILE"
warn "回退会删除三个自研模块的代码、systemd 单元、/etc/freedombox-* 配置目录，"
warn "并移除页脚版权与 404 修复。OpenVPN 的账号库会一并移除。"
warn "freedombox 本体不会被卸载（那是整台机器的基础），管理员账号也会保留。"
warn "如需保留配置，请先自行备份 /etc/freedombox-* 与 /etc/openvpn/freedombox-auth。"

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo
    read -r -p "确认继续？[y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) info "已取消"; exit 0 ;;
    esac
fi

FAILED=0
for id in "${STEP_IDS[@]}"; do
    selected "$id" || continue

    dir=$(step_dir "$id")
    script="$BUNDLE_DIR/payload/$dir/rollback.sh"

    step "[$id] $(step_title "$id")"

    if [ ! -f "$script" ]; then
        warn "  缺少 $script，跳过"
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "  dry-run：将执行 payload/$dir/rollback.sh"
        continue
    fi

    if bash "$script" 2>&1 | tee -a "$LOG_FILE"; then
        ok "  已回退"
    else
        err "  回退失败，请查看日志：$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi
done

banner "回退结束"
if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run 结束：以上为将要执行的步骤，系统未被改动"
    exit 0
fi

if [ "$FAILED" -gt 0 ]; then
    err "$FAILED 个步骤回退失败，请按日志排查"
    exit 1
fi

ok "全部步骤已回退"
info "建议重启一次 Plinth 让状态彻底刷新：systemctl restart plinth"
