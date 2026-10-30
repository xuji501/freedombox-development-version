#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# FreedomBox 定制版 · 离线一键部署
#
# 在一台裸 Debian 13 上装出完整 FreedomBox 并叠加全部定制项：
#   0. FreedomBox 本体（自带离线 apt 源，无需先装 freedombox）
#   1. DHCP 服务器模块（地址池 / 静态绑定 / 租约表）
#   2. IPv6 路由器模块（ULA 前缀 / RA / DHCPv6 / NAT66）
#   3. 路由管理模块（静态路由 + OSPF 动态路由）
#   4. GRE 隧道模块
#   5. OpenVPN 账号管理（服务器设置 + 用户名密码）
#   6. 全站页脚版权信息
#   7. Plinth「404 变 500」修复
#   9. 首次启动向导自动化（建管理员，装完即可登录）
#
# 用法：
#   sudo bash deploy.sh                 # 交互确认后全量部署
#   sudo bash deploy.sh --yes           # 不确认，直接部署
#   sudo bash deploy.sh --dry-run       # 只检查，不动系统
#   sudo bash deploy.sh --only=dhcp,openvpn
#   sudo bash deploy.sh --skip=openvpn
#   sudo bash deploy.sh --force         # 已部署的步骤也重跑
#   sudo bash deploy.sh --rollback-on-error
#
# 部署完成后可用 verify.sh 复核，uninstall.sh 整体回退。

set -uo pipefail

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$BUNDLE_DIR/lib/common.sh"

ASSUME_YES=0
DRY_RUN=0
FORCE=0
ONLY=""
SKIP=""
ROLLBACK_ON_ERROR=0
NO_VERIFY=0

STEP_IDS=(base dhcp ipv6 routes gre openvpn branding fixes firstboot)

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
        *)        echo "$1" ;;
    esac
}

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

usage() {
    cat <<'USAGE'
FreedomBox 定制版 · 离线一键部署

用法：
  sudo bash deploy.sh [选项]

选项：
  -y, --yes               不询问，直接部署
      --dry-run           只做环境检查与步骤规划，不改动系统
      --only=ID[,ID...]   只执行指定步骤
      --skip=ID[,ID...]   跳过指定步骤
      --force             已部署过的步骤也重新执行
      --rollback-on-error 任一步失败时，自动回退本次已完成的步骤
      --no-verify         部署后不跑 verify.sh
  -h, --help              显示本帮助

步骤 ID：
  base      FreedomBox 本体（离线安装，已装则自动跳过）
  dhcp      DHCP 服务器模块
  ipv6      IPv6 路由器模块
  routes    路由管理模块（静态路由 + OSPF）
  gre       GRE 隧道模块
  openvpn   OpenVPN 账号管理
  branding  全站页脚版权信息
  fixes     Plinth「404 变 500」修复
  firstboot 首次启动向导自动化（建管理员，装完即可登录）

示例：
  sudo bash deploy.sh --dry-run
  sudo bash deploy.sh --only=branding,fixes
  sudo bash deploy.sh --skip=openvpn --yes
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)            ASSUME_YES=1 ;;
        --dry-run)           DRY_RUN=1 ;;
        --force)             FORCE=1 ;;
        --only=*)            ONLY="${1#*=}" ;;
        --skip=*)            SKIP="${1#*=}" ;;
        --rollback-on-error) ROLLBACK_ON_ERROR=1 ;;
        --no-verify)         NO_VERIFY=1 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   err "未知参数：$1"; echo; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 载入配置
# ---------------------------------------------------------------------------
[ -f "$BUNDLE_DIR/deploy.conf" ] || die "缺少 deploy.conf"
# shellcheck source=deploy.conf
. "$BUNDLE_DIR/deploy.conf"

FOOTER_TEXT=${FOOTER_TEXT:-}
OVPN_PORT=${OVPN_PORT:-}
OVPN_AUTH_MODE=${OVPN_AUTH_MODE:-cert+pw}
IPV6_PREFIX=${IPV6_PREFIX:-}
IPV6_ENABLE_LAN=${IPV6_ENABLE_LAN:-0}
DHCP_AUTO_ENABLE=${DHCP_AUTO_ENABLE:-0}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}

# 子安装器在独立进程里跑，靠环境变量拿配置。
# OpenVPN 的端口与认证方式用的是 FBX_ 前缀，必须在这里改名导出，
# 否则 deploy.conf 里的这两项对 install.sh 完全不可见。
export ADMIN_USER ADMIN_PASSWORD
export FBX_OVPN_PORT="$OVPN_PORT"
export FBX_OVPN_AUTH_MODE="$OVPN_AUTH_MODE"

STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR=/var/log
LOG_FILE="$LOG_DIR/freedombox-custom-deploy-$STAMP.log"

# ---------------------------------------------------------------------------
# 步骤筛选
# ---------------------------------------------------------------------------
in_list() {
    local needle=$1 list=$2 item
    [ -z "$list" ] && return 1
    local IFS=,
    for item in $list; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

step_selected() {
    if [ -n "$ONLY" ]; then
        in_list "$1" "$ONLY" || return 1
    fi
    if [ -n "$SKIP" ]; then
        in_list "$1" "$SKIP" && return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
preflight() {
    banner "环境检查"

    require_root
    ok "root 权限正常"

    if [ -f /etc/debian_version ]; then
        ok "系统：Debian $(cat /etc/debian_version)（$(. /etc/os-release && echo "$PRETTY_NAME")）"
    else
        warn "未检测到 /etc/debian_version，本包只在 Debian 上验证过"
    fi

    # freedombox 本体：已装则 base 步骤自动跳过；未装则交给 base 步骤从包内
    # 离线源安装。这里只判断「有没有办法装」，不再要求用户预先装好。
    FREEDOMBOX_PRESENT=0
    if dpkg -s freedombox >/dev/null 2>&1; then
        FREEDOMBOX_PRESENT=1
        ok "freedombox 已安装：$(dpkg-query -W -f='${Version}' freedombox)"
    elif step_selected base; then
        if [ -f "$BUNDLE_DIR/payload/00-base/repo/Packages.gz" ]; then
            info "未安装 freedombox，将由 base 步骤从包内离线源安装（无需外网）"
        else
            die "未安装 freedombox，且包内缺少离线源 payload/00-base/repo"
        fi
    else
        die "未安装 freedombox，而本次没有选中 base 步骤。请去掉 --only/--skip 对 base 的排除。"
    fi

    # python3 是 freedombox 的依赖，最小化安装的 Debian 上还没有；
    # base 步骤会把它一起装上，所以这里只在「已装 freedombox」时才硬性要求。
    if have_cmd python3; then
        ok "python3：$(python3 -V 2>&1)"
    elif [ "$FREEDOMBOX_PRESENT" -eq 0 ]; then
        info "python3 尚未安装，base 步骤会随 freedombox 一起装上"
    else
        die "缺少 python3（freedombox 已装却缺它，安装不完整）"
    fi

    if systemctl list-unit-files plinth.service >/dev/null 2>&1; then
        ok "plinth 服务存在"
    elif [ "$FREEDOMBOX_PRESENT" -eq 0 ]; then
        info "plinth.service 尚未注册，base 步骤安装后才会出现"
    else
        die "未找到 plinth.service，freedombox 安装不完整"
    fi

    if [ -d "$PLINTH_LIB" ]; then
        ok "Plinth 代码目录：$PLINTH_LIB"
    elif [ "$FREEDOMBOX_PRESENT" -eq 0 ]; then
        info "Plinth 代码目录将在 base 步骤安装后出现"
    else
        die "找不到 $PLINTH_LIB"
    fi

    # curl 是 freedombox 的依赖，裸机上可能还没有；装了之后 verify.sh 才有得用。
    if have_cmd curl; then
        ok "curl 可用（verify.sh 的 HTTP 自检需要它）"
    elif [ "$FREEDOMBOX_PRESENT" -eq 0 ]; then
        info "curl 尚未安装，base 步骤会随 freedombox 一起装上"
    else
        warn "缺少 curl，verify.sh 的 HTTP 自检会失败"
    fi
    require_cmd sha256sum "用于校验包完整性"

    # 完整性校验：只校验 payload 与 lib，避免因为 deploy.conf 被用户改过而报错。
    # MANIFEST 若被 Windows 编辑器改过会带 CRLF，这里先去掉 \r 再校验。
    if [ -f "$BUNDLE_DIR/MANIFEST.sha256" ]; then
        local manifest_tmp
        manifest_tmp=$(mktemp)
        tr -d '\r' < "$BUNDLE_DIR/MANIFEST.sha256" > "$manifest_tmp"
        if (cd "$BUNDLE_DIR" && sha256sum --quiet -c "$manifest_tmp" >/dev/null 2>&1); then
            ok "包完整性校验通过"
        else
            warn "包完整性校验未通过，payload 可能被改动过"
            (cd "$BUNDLE_DIR" && sha256sum -c "$manifest_tmp" 2>&1 | grep -v ': OK$' | head -20)
        fi
        rm -f "$manifest_tmp"
    else
        warn "缺少 MANIFEST.sha256，跳过完整性校验"
    fi

    local avail need=200
    # 未装 freedombox 时要额外装下约 1.5GB 的包，阈值同步抬高。
    [ "$FREEDOMBOX_PRESENT" -eq 0 ] && need=1600
    avail=$(df -Pk /usr 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    if [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
        if [ "$FREEDOMBOX_PRESENT" -eq 0 ]; then
            die "/usr 剩余空间只有 ${avail}MB，离线安装 freedombox 至少需要 ${need}MB"
        fi
        warn "/usr 剩余空间只有 ${avail}MB，建议至少留 ${need}MB"
    fi

    # 逐步骤的依赖不在这里查：base 步骤会先装上 NetworkManager、dnsmasq、
    # openvpn 等，在裸机上提前查必然全部误报。改成执行到该步骤前再查
    # （见 run_step），此时前面的步骤已经把它们装好了。
    info "各步骤的依赖将在执行到该步骤时检查"

    ok "环境检查全部通过"
}

step_prereq() {
    case "$1" in
        base)
            # 只有「尚未安装」时才会真的执行，此时离线源必须完整。
            if ! dpkg -s freedombox >/dev/null 2>&1; then
                [ -f "$BUNDLE_DIR/payload/00-base/repo/Packages.gz" ] || \
                    { err "缺少离线源索引 payload/00-base/repo/Packages.gz"; return 1; }
                [ -d "$BUNDLE_DIR/payload/00-base/repo/debs" ] || \
                    { err "缺少离线源包目录 payload/00-base/repo/debs"; return 1; }
            fi
            ;;
        dhcp)
            have_cmd nmcli || { err "缺少 nmcli（NetworkManager），DHCP 模块依赖它"; return 1; }
            have_cmd dnsmasq || [ -x /usr/sbin/dnsmasq ] || \
                { err "缺少 dnsmasq，请先 apt install dnsmasq-base"; return 1; }
            ;;
        ipv6)
            have_cmd nft || { err "缺少 nft（nftables），IPv6 模块依赖它"; return 1; }
            have_cmd dnsmasq || [ -x /usr/sbin/dnsmasq ] || \
                { err "缺少 dnsmasq，请先 apt install dnsmasq-base"; return 1; }
            ;;
        routes)
            have_cmd ip || { err "缺少 ip（iproute2）"; return 1; }
            ;;
        gre)
            have_cmd ip || { err "缺少 ip（iproute2）"; return 1; }
            # GRE 靠内核的 ip_gre 模块封装，没有它就建不出隧道。
            # 判可用性按可靠性排序，不能只靠 modprobe：
            #   1. 模块已加载（/proc/modules 或 /sys/module）——容器里也成立
            #   2. modprobe -n 干跑通过（需要 kmod 与 /lib/modules）
            # 最小化 Debian 上没有 kmod，所以 modprobe 可能根本不存在。
            if grep -q '^ip_gre ' /proc/modules 2>/dev/null \
                    || [ -d /sys/module/ip_gre ]; then
                :
            elif have_cmd modprobe && modprobe -n ip_gre >/dev/null 2>&1; then
                :
            else
                err "内核没有 ip_gre 模块，无法创建 GRE 隧道"; return 1
            fi
            ;;
        openvpn)
            [ -x /usr/sbin/openvpn ] || { err "缺少 openvpn，请先 apt install openvpn"; return 1; }
            if [ ! -f /etc/openvpn/server/freedombox.conf ]; then
                [ -x /usr/share/easy-rsa/easyrsa ] || \
                    { err "全新部署 OpenVPN 需要 easy-rsa，请先 apt install easy-rsa"; return 1; }
            fi
            ;;
        firstboot)
            have_cmd systemctl || { err "缺少 systemctl"; return 1; }
            have_cmd debconf-set-selections || { err "缺少 debconf"; return 1; }
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 执行单个步骤
# ---------------------------------------------------------------------------
FAILED_STEP=""
STEP_RAN=0

run_step() {
    local id=$1
    local dir
    dir=$(step_dir "$id")

    STEP_RAN=0
    step "[$id] $(step_title "$id")"

    if ! step_selected "$id"; then
        info "  按参数要求跳过"
        return 0
    fi

    if [ ! -f "$BUNDLE_DIR/payload/$dir/install.sh" ]; then
        err "  缺少 payload/$dir/install.sh"
        FAILED_STEP=$id
        return 1
    fi

    if step_installed "$id" && [ "$FORCE" -eq 0 ]; then
        info "  已部署过，跳过（用 --force 强制重装）"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "  dry-run：将执行 payload/$dir/install.sh"
        return 0
    fi

    # 依赖在这里查而不是 preflight：前面的步骤可能刚把它们装上。
    if ! step_prereq "$id"; then
        err "  $(step_title "$id") 的前置依赖不满足"
        FAILED_STEP=$id
        return 1
    fi

    local start=$SECONDS
    STEP_RAN=1
    bash "$BUNDLE_DIR/payload/$dir/install.sh" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    local spent=$((SECONDS - start))

    if [ "$rc" -ne 0 ]; then
        err "  $(step_title "$id") 部署失败（退出码 $rc，耗时 ${spent}s）"
        FAILED_STEP=$id
        return 1
    fi

    ok "  $(step_title "$id") 完成（${spent}s）"
    return 0
}

# ---------------------------------------------------------------------------
# 部署后的可选配置
# ---------------------------------------------------------------------------
postconfig() {
    local args=()
    if [ "$DHCP_AUTO_ENABLE" = "1" ] && step_selected dhcp; then
        args+=(--dhcp-enable)
    fi
    if [ -n "$IPV6_PREFIX" ] && step_selected ipv6; then
        args+=(--ipv6-prefix "$IPV6_PREFIX")
    fi
    if [ "$IPV6_ENABLE_LAN" = "1" ] && step_selected ipv6; then
        args+=(--ipv6-enable-lan)
    fi

    [ ${#args[@]} -eq 0 ] && return 0

    banner "应用 deploy.conf 中的附加配置"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run：将执行 lib/postconfig.py ${args[*]}"
        return 0
    fi
    (cd /usr/lib/python3/dist-packages && python3 "$BUNDLE_DIR/lib/postconfig.py" "${args[@]}")
    if [ $? -ne 0 ]; then
        err "附加配置应用失败，请手动在页面上确认"
        return 1
    fi
    ok "附加配置已应用"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
: >"$LOG_FILE"
chmod 600 "$LOG_FILE"

banner "FreedomBox 定制版 v1.0.4 · 离线一键部署"
info "包目录：$BUNDLE_DIR"
info "日志文件：$LOG_FILE"
[ "$DRY_RUN" -eq 1 ] && warn "dry-run 模式：只检查与规划，不改动系统"

preflight

# 计划摘要
banner "部署计划"
for id in "${STEP_IDS[@]}"; do
    if ! step_selected "$id"; then
        printf '  %-10s %s\n' "$id" "跳过（参数排除）" | tee -a "$LOG_FILE"
    elif step_installed "$id" && [ "$FORCE" -eq 0 ]; then
        printf '  %-10s %s\n' "$id" "已部署，跳过" | tee -a "$LOG_FILE"
    else
        printf '  %-10s %s\n' "$id" "$(step_title "$id")" | tee -a "$LOG_FILE"
    fi
done

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo
    read -r -p "确认开始部署？[y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) info "已取消"; exit 0 ;;
    esac
fi

if [ "$DRY_RUN" -eq 0 ]; then
    banner "创建全局快照"
    SNAPSHOT=$(global_snapshot "$STAMP")
    ok "快照目录：$SNAPSHOT"
    info "（各步骤另有自己的备份目录，见 /root/freedombox-*-backup/）"
fi

COMPLETED=()

for id in "${STEP_IDS[@]}"; do
    if run_step "$id"; then
        [ "$STEP_RAN" -eq 1 ] && COMPLETED+=("$id")
    else
        err "部署在第 $id 步中断"
        err "日志：$LOG_FILE"
        if [ "$ROLLBACK_ON_ERROR" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
            warn "按 --rollback-on-error 要求回退本次已完成的步骤"
            bash "$BUNDLE_DIR/uninstall.sh" --yes --only="$(IFS=,; echo "${COMPLETED[*]}")" || true
        else
            warn "可执行 sudo bash $BUNDLE_DIR/uninstall.sh 整体回退"
        fi
        exit 1
    fi
done

if ! postconfig; then
    warn "附加配置未完全应用，可稍后在页面上手动设置"
fi

if [ "$NO_VERIFY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    bash "$BUNDLE_DIR/verify.sh" || warn "自检存在未通过项，请查看上面的输出"
fi

banner "部署结束"
ok "日志文件：$LOG_FILE"

# 首次启动自动化生成的管理员凭据：这是登录 Plinth 的唯一入口，必须显式提示。
if [ -s /root/freedombox-admin-password.txt ]; then
    info "管理员账号信息（同时保存在 /root/freedombox-admin-password.txt）："
    grep -E '^(username|password)=' /root/freedombox-admin-password.txt | sed 's/^/  /'
fi

info "访问 https://<本机地址>/plinth/ 查看效果"
info "整体回退：sudo bash $BUNDLE_DIR/uninstall.sh"
