#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# FreedomBox 定制版 · 部署后自检
#
# 只读检查，不改动任何东西。用法：sudo bash verify.sh
# 全部通过时退出码为 0，有失败项时为 1。

set -uo pipefail

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$BUNDLE_DIR/lib/common.sh"

STAMP=$(date +%Y%m%d-%H%M%S)
# common.sh 已经把 LOG_FILE 默认成 /dev/null，这里必须直接赋值而不是用 :- 兜底。
LOG_FILE="/var/log/freedombox-custom-verify-$STAMP.log"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/freedombox-custom-verify-$STAMP.log"

PASS=0
FAIL=0
WARN=0

pass() {
    PASS=$((PASS + 1))
    _emit "[通过]" "$_C_OK" "$*"
}

failed() {
    FAIL=$((FAIL + 1))
    _emit "[失败]" "$_C_ERR" "$*"
}

warned() {
    WARN=$((WARN + 1))
    _emit "[警告]" "$_C_WARN" "$*"
}

# 检查一个 systemd 单元是否 active。
# 模板实例（openvpn-server@freedombox.service）不会出现在 list-unit-files 的
# 精确匹配结果里，存在性要回退到模板名判断。
check_unit() {
    local unit=$1 label=${2:-$1}
    local state exists=0
    state=$(systemctl is-active "$unit" 2>/dev/null || true)

    if [ "$state" = "active" ]; then
        pass "$label：active"
        return
    fi

    if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q .; then
        exists=1
    elif [[ "$unit" == *@* ]]; then
        local tmpl="${unit%%@*}@.service"
        if systemctl list-unit-files --no-legend "$tmpl" 2>/dev/null | grep -q .; then
            exists=1
        fi
    fi

    if [ "$exists" -eq 1 ]; then
        failed "$label：${state:-inactive}（单元存在但未运行）"
    else
        failed "$label：单元不存在"
    fi
}

# 取一个 URL 的状态码
http_code() {
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1/plinth$1" \
        2>/dev/null || echo 000
}

http_body() {
    curl -sk --max-time 10 "https://127.0.0.1/plinth$1" 2>/dev/null || true
}

banner "FreedomBox 定制版 · 部署自检"
info "日志文件：$LOG_FILE"

# ---------------------------------------------------------------------------
banner "1. 系统基线"
# ---------------------------------------------------------------------------
if dpkg -s freedombox >/dev/null 2>&1; then
    fb_version=$(dpkg-query -W -f='${Version}' freedombox)
    pass "freedombox 已安装：$fb_version"
    # 本包是按 25.9.3 的 Plinth 内部结构改的，跨大版本可能对不上。
    case "$fb_version" in
        25.9.*) pass "freedombox 版本在验证范围内（25.9.x）" ;;
        *)      warned "freedombox 版本为 $fb_version，本包只在 25.9.x 上验证过" ;;
    esac
else
    failed "未安装 freedombox 软件包"
fi

# 首次启动自动化是否跑过：没有这个标记，网页会一直跳到向导。
if [ -f /etc/freedombox-custom/firstboot-done ]; then
    pass "首次启动向导已自动化完成"
else
    warned "缺少 /etc/freedombox-custom/firstboot-done（网页可能仍会跳向导）"
fi

# 管理员账号：Django 侧有用户，且 Linux 侧在 admin 组里，两边都要有。
if [ -s /root/freedombox-admin-password.txt ]; then
    admin_user=$(sed -n 's/^username=//p' /root/freedombox-admin-password.txt | head -1)
    if [ -n "$admin_user" ] && id -nG "$admin_user" 2>/dev/null | tr ' ' '\n' \
            | grep -qx admin; then
        pass "管理员账号存在且属于 admin 组：$admin_user"
    else
        failed "管理员账号 ${admin_user:-未知} 不存在或不在 admin 组"
    fi
else
    warned "缺少 /root/freedombox-admin-password.txt，无法确认管理员账号"
fi

# 「装完即可登录」的硬证明：拿这份密码真的登录一次，再访问一个必须登录
# 才能看的页面。只看登录页返回 200 是没用的，LDAP 认证失败时它照样 200。
if [ -s /root/freedombox-admin-password.txt ] && have_cmd python3; then
    login_output=$(python3 "$BUNDLE_DIR/lib/login_check.py" 2>&1)
    login_rc=$?
    printf '%s\n' "$login_output" | sed 's/^/    /'
    if [ "$login_rc" -eq 0 ]; then
        pass "管理员账号可通过网页真实登录"
    else
        failed "管理员账号无法登录网页：$(printf '%s' "$login_output" | head -1)"
    fi
fi

# ---------------------------------------------------------------------------
banner "2. 基础服务"
# ---------------------------------------------------------------------------
check_unit plinth.service "Plinth"

# ---------------------------------------------------------------------------
banner "3. 定制模块"
# ---------------------------------------------------------------------------
for id in dhcp ipv6 routes gre; do
    if [ -f "$ENABLED_DIR/$id" ]; then
        pass "模块启用标记：/etc/freedombox/modules-enabled/$id"
    else
        failed "模块启用标记缺失：/etc/freedombox/modules-enabled/$id"
    fi

    if [ -d "$PLINTH_LIB/modules/$id" ]; then
        local_count=$(find "$PLINTH_LIB/modules/$id" -name '*.py' ! -path '*__pycache__*' | wc -l)
        pass "模块代码目录：plinth/modules/$id（$local_count 个 .py）"
    else
        failed "模块代码目录缺失：plinth/modules/$id"
    fi
done

# DHCP 与 IPv6 的服务单元只在「启用」之后才会被写出来：未启用时模块有意
# 不装单元，免得开机就拉起一个没有配置的服务。所以这里先读配置再判断——
# 启用了就必须 active，没启用只核对模块本身（前面已查过）。
dhcp_enabled=$(python3 -c "
import json
try:
    print('1' if json.load(open('/etc/freedombox-dhcp/settings.json')).get('enabled') else '0')
except Exception:
    print('0')
" 2>/dev/null)
if [ "$dhcp_enabled" = "1" ]; then
    check_unit freedombox-dhcp.service "freedombox-dhcp"
else
    info "DHCP 未启用（settings.json 里 enabled 为 false），跳过服务单元检查"
fi

ipv6_lan=$(python3 -c "
import json
try:
    print('1' if json.load(open('/etc/freedombox-ipv6/settings.json')).get('lan_enabled') else '0')
except Exception:
    print('0')
" 2>/dev/null)
if [ "$ipv6_lan" = "1" ]; then
    check_unit freedombox-ipv6.service "freedombox-ipv6"
    check_unit freedombox-ipv6-ra.service "freedombox-ipv6-ra"
else
    info "IPv6 内网未启用（lan_enabled 为 false），跳过服务单元检查"
fi

check_unit freedombox-routes.service "freedombox-routes"
check_unit freedombox-gre.service "freedombox-gre"

# GRE 隧道：内核封装模块必须在，否则建不出任何隧道。
# 已加载（/proc/modules 或 /sys/module）同样算可用 —— 容器里往往没有
# /lib/modules，最小化 Debian 上甚至没有 modprobe。
if grep -q '^ip_gre ' /proc/modules 2>/dev/null || [ -d /sys/module/ip_gre ] \
        || { command -v modprobe >/dev/null 2>&1 && modprobe -n ip_gre >/dev/null 2>&1; }; then
    pass "内核 GRE 模块可用（ip_gre）"
else
    failed "内核缺少 ip_gre 模块，GRE 隧道无法创建"
fi

# 隧道清单存在但一条都没配，属于「装了没用」，只提示不判失败。
if [ -f /etc/freedombox-gre/tunnels.json ]; then
    gre_count=$(python3 - <<'PY' 2>/dev/null || echo 0
import json
try:
    data = json.load(open('/etc/freedombox-gre/tunnels.json'))
except Exception:
    print(0)
else:
    items = data.get('tunnels') if isinstance(data, dict) else data
    print(len(items or []))
PY
)
    if [ "$gre_count" -gt 0 ]; then
        pass "已配置 $gre_count 条 GRE 隧道"
        while IFS= read -r line; do
            [ -n "$line" ] && info "  $line"
        done < <(ip -br link show type gre 2>/dev/null | awk '$1 != "gre0" {print "接口 " $1 " 状态 " $2}')
    else
        warned "隧道清单为空（模块已装好，尚未配置隧道）"
    fi
else
    warned "缺少 /etc/freedombox-gre/tunnels.json（GRE 模块可能还没初始化）"
fi

# OSPF：FRR 是可选的，没装说明用户没打算跑动态路由，不算失败。
if [ -f /etc/frr/frr.conf ]; then
    if grep -q 'freedombox-ospf begin' /etc/frr/frr.conf 2>/dev/null; then
        pass "frr.conf 中存在本模块管理的 OSPF 配置块"
        if systemctl is-active --quiet frr; then
            pass "frr 服务运行中"
            nbr=$(vtysh -c 'show ip ospf neighbor' 2>/dev/null \
                  | grep -c 'Full' || true)
            info "  OSPF 邻居（Full）：$nbr"
        else
            warned "frr 已安装但未运行（OSPF 尚未启用？）"
        fi
    else
        info "frr.conf 里没有本模块的 OSPF 配置块（OSPF 未启用，属正常）"
    fi
else
    info "未安装 FRR，跳过 OSPF 检查（静态路由不受影响）"
fi

# ---------------------------------------------------------------------------
banner "4. OpenVPN 账号管理"
# ---------------------------------------------------------------------------
if [ -x /usr/lib/freedombox-openvpn/ovpn-auth.py ]; then
    pass "凭据校验脚本：/usr/lib/freedombox-openvpn/ovpn-auth.py"
else
    failed "凭据校验脚本缺失"
fi

if [ -f /etc/openvpn/freedombox-auth/users.json ]; then
    perm=$(stat -c '%a' /etc/openvpn/freedombox-auth/users.json)
    if [ "$perm" = "600" ] || [ "$perm" = "640" ] || [ "$perm" = "644" ]; then
        pass "账号库存在（权限 $perm）"
    else
        warned "账号库权限为 $perm，建议收紧到 600"
    fi
else
    failed "账号库缺失：/etc/openvpn/freedombox-auth/users.json"
fi

ovpn_auth_mode=$(python3 -c "
import json
try:
    print(json.load(open('/etc/openvpn/server/freedombox-settings.json')).get('auth_mode', 'cert'))
except Exception:
    print('cert')
" 2>/dev/null)
if [ "$ovpn_auth_mode" = "cert+pw" ]; then
    if grep -q 'auth-user-pass-verify /usr/lib/freedombox-openvpn/ovpn-auth.py' \
            /etc/openvpn/server/freedombox.conf 2>/dev/null; then
        pass "服务端配置已指向新的校验脚本（cert+pw）"
    else
        failed "认证方式为 cert+pw，但服务端配置未挂载校验脚本"
    fi
else
    if grep -q 'auth-user-pass-verify' /etc/openvpn/server/freedombox.conf 2>/dev/null; then
        warned "认证方式为 ${ovpn_auth_mode:-cert}，但服务端配置里仍残留 auth-user-pass-verify"
    else
        pass "认证方式为 ${ovpn_auth_mode:-cert}（纯证书，未启用密码校验）"
    fi
fi

check_unit openvpn-server@freedombox.service "openvpn-server@freedombox"

# ---------------------------------------------------------------------------
banner "5. 页脚版权信息"
# ---------------------------------------------------------------------------
BASE_TEMPLATE=$PLINTH_LIB/templates/base.html
if grep -q 'plinth-branding:start' "$BASE_TEMPLATE" 2>/dev/null; then
    pass "base.html 中存在版权块标记"
else
    failed "base.html 中缺少版权块标记（apt upgrade freedombox 会还原，需重跑）"
fi

# ---------------------------------------------------------------------------
banner "6. Plinth 404 修复"
# ---------------------------------------------------------------------------
if grep -q 'plinth-fix-404:start' "$PLINTH_LIB/views.py" 2>/dev/null; then
    pass "views.py 中存在 404 修复标记"
else
    failed "views.py 中缺少 404 修复标记（apt upgrade freedombox 会还原，需重跑）"
fi

code=$(http_code "/this-page-should-not-exist/")
case "$code" in
    404) pass "访问不存在的地址返回 404" ;;
    500) failed "访问不存在的地址仍返回 500（修复未生效）" ;;
    *)   warned "访问不存在的地址返回 $code" ;;
esac

# ---------------------------------------------------------------------------
banner "7. 页面可达性"
# ---------------------------------------------------------------------------
code=$(http_code "/accounts/login/")
if [ "$code" = "200" ]; then
    pass "登录页 200"
    body=$(http_body "/accounts/login/")
    footer_text=$(grep -o 'FreedomBox 定制版[^<]*' <<<"$body" | head -1)
    if [ -n "$footer_text" ]; then
        pass "登录页页脚：$footer_text"
    else
        failed "登录页未渲染出页脚版权信息"
    fi
else
    failed "登录页返回 $code"
fi

# 需要登录的页面：未认证时 302 到登录页属正常，404/500 才是问题。
# 注意路由位置：DHCP 与 OpenVPN 挂在 /apps/ 下，IPv6 与静态路由挂在 /sys/ 下。
for path in / /apps/ /apps/dhcp/ /apps/openvpn/ \
            /sys/ /sys/ipv6/ /sys/routes/ /sys/routes/ospf/ /sys/gre/ \
            /sys/networks/ /sys/users/; do
    code=$(http_code "$path")
    case "$code" in
        200|302) pass "$path -> $code" ;;
        404)     failed "$path -> 404（路由未注册）" ;;
        500)     failed "$path -> 500（服务端异常）" ;;
        *)       warned "$path -> $code" ;;
    esac
done

# ---------------------------------------------------------------------------
banner "8. 配置文件与模块版本"
# ---------------------------------------------------------------------------
for path in /etc/freedombox-dhcp/settings.json \
            /etc/freedombox-ipv6/settings.json \
            /etc/freedombox-routes/routes.json \
            /etc/freedombox-gre/tunnels.json \
            /etc/openvpn/server/freedombox-settings.json; do
    if [ -f "$path" ]; then
        pass "存在 $path"
    else
        warned "缺少 $path（对应模块可能还没初始化）"
    fi
done

python3 - <<'PY' 2>/dev/null || warned "无法读取 Plinth 模块版本表"
import sqlite3

expected = {'dhcp': 1, 'ipv6': 1, 'routes': 2, 'gre': 1, 'openvpn': 6}
con = sqlite3.connect('/var/lib/plinth/plinth.sqlite3')
rows = dict(con.execute('select name, setup_version from plinth_module'))
for name, version in expected.items():
    actual = rows.get(name)
    if actual is None:
        print('[警告] 模块 {} 未记录 setup 版本'.format(name))
    elif actual < version:
        print('[警告] 模块 {} 版本 {} < 期望 {}'.format(name, actual, version))
    else:
        print('[通过] 模块 {} setup 版本 {}'.format(name, actual))
PY

# ---------------------------------------------------------------------------
banner "自检结果"
# ---------------------------------------------------------------------------
info "通过 $PASS 项，警告 $WARN 项，失败 $FAIL 项"
info "日志：$LOG_FILE"

if [ "$FAIL" -gt 0 ]; then
    err "存在失败项，请按上面的提示排查"
    exit 1
fi

ok "全部关键项通过"
exit 0
