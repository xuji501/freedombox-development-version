# FreedomBox 定制版 · 离线一键部署包 v1.0.4

在**一台裸 Debian 13** 上，用一条命令装出完整 FreedomBox 并叠加全部定制项。

目标机器**不需要预先安装 freedombox**，也**不需要能访问任何 Debian 源** ——
包内自带一份本地 apt 源（458 个 deb，约 160MB），freedombox 本体和它依赖的一切
都在里面。首次启动向导（wizard secret → 建管理员 → backports）也由脚本代做，
装完直接用网页登录。

---

## 一、包里有什么

| # | 内容 | 说明 | 落盘位置 |
|---|------|------|----------|
| 0 | FreedomBox 本体 | freedombox 25.9.3+deb13u1 及其 458 个依赖包，从包内离线源安装 | 系统全局 |
| 1 | DHCP 服务器模块 | 地址池、网关、DNS、租期、静态绑定、租约表、在线设备 | `plinth/modules/dhcp/`、`/etc/freedombox-dhcp/`、`/var/lib/freedombox-dhcp/` |
| 2 | IPv6 路由器模块 | ULA 前缀、RA、DHCPv6、NAT66、在线设备（IPv6） | `plinth/modules/ipv6/`、`/etc/freedombox-ipv6/`、`/usr/lib/freedombox-ipv6/` |
| 3 | 路由管理模块 | 静态路由（按网段/主机，开机自动恢复）+ OSPF 动态路由（区域/接口/邻居，基于 FRR） | `plinth/modules/routes/`、`/etc/freedombox-routes/`、`/etc/frr/frr.conf`（标记块） |
| 4 | GRE 隧道模块 | 隧道增删改、MTU/MSS 钳制、防火墙自动放通、开机自恢复 | `plinth/modules/gre/`、`/etc/freedombox-gre/`、`/usr/lib/freedombox-gre/` |
| 5 | OpenVPN 账号管理 | 服务器端口与认证方式可配、用户名密码账号管理、客户端 profile 下发 | `plinth/modules/openvpn/`、`/usr/lib/freedombox-openvpn/`、`/etc/openvpn/freedombox-auth/` |
| 6 | 全站页脚版权 | 所有页面底部一行版权信息 | `plinth/templates/base.html` |
| 7 | Plinth 404 修复 | 修复「访问不存在的地址返回 500 而不是 404」 | `plinth/views.py` |
| 9 | 首次启动自动化 | 建管理员账号、标记向导完成，装完即可登录 | `/etc/freedombox-custom/`、`/root/freedombox-admin-password.txt` |

四个自研模块（1/2/3/4）**不属于 freedombox deb 包**，`apt upgrade` 不会覆盖它们。
第 5/6/7 项改的是 deb 包内的文件，`apt upgrade freedombox` 会把它们还原 ——
升级后重跑一次 `deploy.sh` 即可（会自动识别缺失并只补这几项）。

---

## 二、目标机器要求

- Debian 13 (trixie)，**amd64**，最小化安装即可（不需要桌面）
- root 权限
- 磁盘：`/usr` 至少留 1.6GB（装 freedombox 及其依赖约需 1.5GB）
- **不需要外网**。要外网也能跑，但完全用不上

如果目标机上已经装好了 freedombox（老机器升级场景），`base` 步骤会自动跳过，
只叠加定制项 —— 同一个包两种场景都能用。

---

## 三、用法

```bash
# 1. 解包
tar xzf freedombox-custom-v1.0.4.tar.gz
cd freedombox-custom

# 2. 先干跑一遍，确认环境与计划（不改动系统）
sudo bash deploy.sh --dry-run

# 3. 正式部署（一条命令，全程无人值守）
sudo bash deploy.sh --yes

# 4. 自检
sudo bash verify.sh
```

部署结束后终端会打印管理员账号与密码，同时保存在
`/root/freedombox-admin-password.txt`（权限 600）。直接打开
`https://<本机地址>/plinth/` 登录即可，不会再跳首次启动向导。

### 常用参数

| 参数 | 说明 |
|------|------|
| `-y, --yes` | 不询问，直接部署 |
| `--dry-run` | 只做环境检查与步骤规划，不改动系统 |
| `--only=base,dhcp` | 只执行指定步骤 |
| `--skip=openvpn` | 跳过指定步骤 |
| `--force` | 已部署过的步骤也重新执行 |
| `--rollback-on-error` | 任一步失败时自动回退本次已完成的步骤 |
| `--no-verify` | 部署后不跑自检 |

步骤 ID：`base` `dhcp` `ipv6` `routes` `gre` `openvpn` `branding` `fixes` `firstboot`

> `base` 与 `firstboot` 请勿用 `--only` 排除掉，否则装出来会缺 FreedomBox 本体
> 或登录不了。

---

## 四、部署前请先改 `deploy.conf`

`deploy.conf` 是纯 shell 变量赋值，改完直接重跑即可。

```bash
# 管理员账号；密码留空 = 自动生成 16 位随机串
ADMIN_USER="admin"
ADMIN_PASSWORD=""

# 页脚文案
FOOTER_TEXT="FreedomBox 定制版，起点火箭开发 20261028，版本号 v1.0.1"

# OpenVPN 端口；留空 = 已有配置就沿用，否则 1194
OVPN_PORT=""

# cert（仅证书） 或 cert+pw（证书 + 用户名密码）
OVPN_AUTH_MODE="cert"

# IPv6 内网 ULA 前缀；留空 = 自动生成，避免多台设备冲突
IPV6_PREFIX=""

# 部署完是否立刻启用（1=启用）。两者都会改变网络行为，默认 0，只装不启用。
IPV6_ENABLE_LAN=0
DHCP_AUTO_ENABLE=0
```

**默认值是刻意保守的**：模块装好、页面能打开，但不会去动网卡、地址池、路由通告。
确认过页面上的参数之后再手动启用，避免一键部署把机器从网络上打下去。

选 `OVPN_AUTH_MODE="cert+pw"` 时，**必须先到 OpenVPN 页面建账号**，否则任何客户端都连不上。

---

## 五、部署过程做了什么

1. **环境检查**：root、Debian、架构、磁盘空间、离线源完整性、各步骤依赖、包完整性
2. **全局快照**：把将被改动的文件与目录拷到 `/var/backups/freedombox-custom/<时间戳>/`
3. 按顺序执行九个步骤：

   | 步骤 | 做什么 |
   |------|--------|
   | `base` | 预置 debconf → 挂包内离线源 → `apt install freedombox dnsmasq-base openvpn easy-rsa frr kmod` → 撤源 |
   | `dhcp` `ipv6` `routes` `gre` | 各模块源码落盘 → 语法/导入校验 → 重启 plinth → 验证，失败自动回滚该步 |
   | `openvpn` | 服务器设置与账号管理改造（fresh 分支会生成 CA 与服务端证书） |
   | `branding` `fixes` | 页脚版权与 404 修复 |
   | `firstboot` | 停 plinth → `plinth --setup-no-install` 配置必备应用 → 建管理员 → 标记向导完成 → 重启 plinth |

4. **附加配置**：按 `deploy.conf` 应用端口、认证方式、IPv6 前缀等
5. **自检**：系统基线、服务状态、页面可达性、页脚、404、模块版本

日志：`/var/log/freedombox-custom-deploy-<时间戳>.log`

每步另有自己的备份目录：

```
/root/freedombox-dhcp-module-backup/<时间戳>/
/root/freedombox-ipv6-module-backup/<时间戳>/
/root/freedombox-routes-module-backup/<时间戳>/
/root/freedombox-gre-module-backup/<时间戳>/
/root/freedombox-openvpn-users-backup/<时间戳>/
/root/freedombox-branding-backup/<时间戳>/
/root/freedombox-fixes-backup/<时间戳>/
```

---

## 六、回退

```bash
# 整体回退（按部署相反顺序）
sudo bash uninstall.sh

# 只撤其中几项
sudo bash uninstall.sh --only=branding,fixes
```

单独撤某一项也可以直接用它自己的脚本，例如：

```bash
sudo bash payload/50-branding/rollback.sh
sudo bash payload/40-openvpn/rollback.sh /root/freedombox-openvpn-users-backup/20261028-120000
```

**`base` 步骤不支持回退**：卸载 freedombox 会连带删掉 Plinth 配置、LDAP 数据与
用户账号，风险远大于收益。`uninstall.sh` 不会碰它。真要拆请自行
`apt purge freedombox` 并承担后果。

`firstboot` 的回退只是清掉完成标记（网页会重新进向导），**不会删管理员账号** ——
删掉最后一个管理员就再也登不进 Plinth 了。

---

## 七、部署后

1. 打开 `https://<本机地址>/plinth/`，用部署时生成的管理员账号登录
2. 左侧「应用」里会出现 **DHCP 服务器**、**IPv6 路由器**、**路由管理**、**GRE 隧道**；
   OpenVPN 页面多出「服务器设置」与「账号管理」两块
3. 按需在页面上启用：
   - DHCP：选内网网卡、地址池、网关、DNS → 保存（这一步会切换网卡地址）
   - IPv6：选 WAN/LAN 网卡、前缀 → 保存（这一步会开转发与路由通告）
   - 路由管理：静态路由页加网段；OSPF 页选区域、加接口
   - GRE 隧道：填本端/对端地址、隧道地址与 MTU → 保存（防火墙会自动放通协议 47）
   - OpenVPN：设端口与认证方式 → 建账号 → 下载 profile

### 已知注意事项

- **应用出现在「已禁用」列表**：Plinth 只在服务启动时计算一次启用状态，
  模块文件在运行期被替换就会残留旧状态。`systemctl restart plinth` 即可。
- **`apt upgrade freedombox` 之后**：页脚版权与 404 修复会被还原。
  重跑 `sudo bash deploy.sh --only=branding,fixes` 补回来。
  自研模块与 OpenVPN 改造不受影响（前者不在包内，后者会被还原，需重跑
  `--only=openvpn`）。
- **跨大版本升级要小心**：本包是按 freedombox 25.9.3 的 Plinth 内部结构改的。
  升级到 26.x 后自研模块可能需要适配，`verify.sh` 会对非 25.9.x 版本给出警告。
- **OpenVPN 全新部署**（目标机从未启用过 OpenVPN）：安装脚本会自动走
  fresh 分支，生成 CA 与服务端证书、写服务端配置、放行防火墙。
  已有配置的机器走 upgrade 分支，**不会**重新生成证书。

---

## 八、目录结构

```
freedombox-custom/
├── deploy.sh              一键部署入口
├── uninstall.sh           整体回退
├── verify.sh              部署后自检（只读）
├── deploy.conf            部署参数
├── MANIFEST.sha256        payload 完整性清单（不含离线源里的 deb）
├── lib/
│   ├── common.sh          日志、断言、状态判定、全局快照
│   └── postconfig.py      应用 deploy.conf 中的附加配置
└── payload/
    ├── 00-base/           install.sh + preseed.sh + rollback.sh
    │   └── repo/          离线 apt 源：Packages / Packages.gz / Release / debs/*.deb
    ├── 10-dhcp/           模块源码 + install.sh + rollback.sh + setup_once.py
    ├── 20-ipv6/           模块源码 + install.sh + rollback.sh + init_once.py
    ├── 30-routes/         模块源码（含 OSPF）+ install.sh + rollback.sh + init_once.py
    ├── 35-gre/            模块源码 + install.sh + rollback.sh + init_once.py
    ├── 40-openvpn/        模块源码 + install.sh + rollback.sh + init_once.py + bootstrap.py
    ├── 50-branding/       apply_footer.py + install.sh + rollback.sh
    ├── 60-fixes/          fix_404.py + install.sh + rollback.sh
    └── 90-firstboot/      firstboot.py + install.sh + rollback.sh
```

每个 `payload/<步骤>/` 都可以单独拿出来用：进到目录里 `sudo bash install.sh` 就是
只装这一项，`sudo bash rollback.sh` 就是只撤这一项。

---

## 九、离线源是怎么来的

离线源是构建机上预先下好的 deb 缓存，构建时整体拷进包里：

```
dist/repo-cache/fbx-repo/
├── Packages          apt-ftparchive 生成的索引（含每个包的 SHA256）
├── Packages.gz       同上，gzip 压缩
└── debs/             458 个 .deb
```

重新生成（需要一台能访问 Debian 源的 Debian 13 amd64 机器）：

```bash
# 1. 算出「裸系统装 freedombox + 本包要用的工具」的完整依赖闭包
apt-get -o Dir::State::status=/dev/null -y --print-uris \
        install --no-install-recommends \
        freedombox/trixie dnsmasq-base openvpn easy-rsa frr kmod > uris.txt

# 2. 逐个下载（--print-uris 的每行格式：'URL' 文件名 字节数 哈希）
grep "^'" uris.txt | sed "s/^'\([^']*\)' \([^ ]*\) \([0-9]*\).*/\1 \2/" \
  | while read -r url name; do curl -fsSL -o "debs/$name" "${url#tor+}"; done

# 3. 建索引
apt-ftparchive packages debs > Packages && gzip -9 -kf Packages
```

`Dir::State::status=/dev/null` 是关键：它让 apt 以为系统上一个包都没装，
从而算出完整的依赖闭包，而不是「本机还差哪几个」。

版本刻意钉在 trixie 的 `freedombox 25.9.3+deb13u1`，不取 backports 的 26.x。

---

## 十、排障

| 现象 | 处理 |
|------|------|
| `base` 报「离线源不完整」 | 包没传完整，重新拷一次；或核对 `payload/00-base/repo/debs` 下应有 458 个 `.deb` |
| `base` 报 `apt-get install` 失败 | 看日志里最后一个 `E:` 行；多为磁盘不足（需 1.6GB）或 debconf 预置被覆盖 |
| 装完网页仍跳首次启动向导 | `sudo bash deploy.sh --only=firstboot --force` 重跑；仍不行看 `/var/log/` 里 firstboot 的输出 |
| 忘记管理员密码 | `cat /root/freedombox-admin-password.txt`；或 `sudo bash deploy.sh --only=firstboot --force` 重置 |
| 部署卡在某一步 | 看 `/var/log/freedombox-custom-deploy-*.log`，该步已自动回滚，修完依赖重跑即可 |
| `plinth` 起不来 | `journalctl -u plinth -n 80 --no-pager`，多数是某步的 Python 语法问题，用对应 `rollback.sh` 撤回 |
| 页面 500 | `journalctl -u plinth -n 80`，再看 `verify.sh` 的输出定位是哪一项 |
| 模块装好但应用页没有 | `systemctl restart plinth`；仍没有则检查 `/etc/freedombox/modules-enabled/` 下标记文件 |
| DHCP 启用了但客户端拿不到地址 | 确认内网网卡选对、地址池与网关同网段、`systemctl status freedombox-dhcp` |
| IPv6 在线设备表为空 | 确认 `lan_enabled` 已开、内网网卡选对，且客户端确实通过 SLAAC 拿到了前缀内的地址 |
| OpenVPN 连不上 | 页面确认端口、认证方式；`cert+pw` 模式下必须有已启用账号；`journalctl -u openvpn-server@freedombox` |
| 在 **容器**里测试时 firewall 应用 setup 失败（`firewall-cmd ... exit status 111`） | 容器缺少 iptables 后端，`firewall-cmd --direct --add-passthrough ipv4` 必然失败，`plinth` 会每 10 秒重试首启 setup、页面一直停在「正在初始化」。**真机不受影响**（本包在 172.16.19.61 上 firewall setup 一次通过）。容器内验证可把 firewall 标记为已 setup 后重启 `plinth` |
| `sudo: unable to resolve host <主机名>` | 最小化 Debian（debootstrap）的 `/etc/hosts` 只有 localhost。`base` 与 `firstboot` 步骤已自动补 `127.0.1.1 <主机名>`；若仍报，手动执行 `echo "127.0.1.1 $(cat /etc/hostname)" >> /etc/hosts` |
