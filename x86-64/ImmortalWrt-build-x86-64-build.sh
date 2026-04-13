#!/bin/bash
set -e

echo "========== 开始 GitHub 极速纯净版构建 (含全自动静默升级) =========="

# ==========================================
# 1. 基础网络参数提取
# ==========================================
INPUT_IP=${MANAGEMENT_IP:-192.168.100.1}
IP_ADDR=$(echo "$INPUT_IP" | cut -d'/' -f1)
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}

# ==========================================
# 2. 极致优化：分区锁定与冗余镜像剔除
# ==========================================
echo ">>> 执行极致优化：砍掉所有不必要的虚拟机格式..."
sed -i '/CONFIG_TARGET_KERNEL_PARTSIZE/d' .config
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
sed -i '/CONFIG_TARGET_ROOTFS_PARTSIZE/d' .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

# ==========================================
# 3. 准备系统目录 & 预埋 Meta 核心
# ==========================================
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core files/etc/config files/usr/bin files/etc/crontabs

echo ">>> 正在预埋 OpenClash Meta 核心..."
META_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
wget -qO- "$META_CORE_URL" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta

# ==========================================
# 4. 编写全自动静默升级脚本 (防砖双引擎版)
# ==========================================
echo ">>> 正在植入全自动静默升级脚本与定时任务..."
cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
LOGFILE="/root/upg.log"

# 日志防爆机制：超过 1MB 自动清空
if [ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt 1048576 ]; then
    echo "日志过大，已清空重建" > "$LOGFILE"
fi

echo "===== Auto Upgrade Start: $(date) =====" >> "$LOGFILE"

# 1. 嗅探当前环境 (适配 24.10+ 和 23.05-)
if command -v apk >/dev/null 2>&1; then
    PKG_ENGINE="apk"
    openclash_before=$(apk info -v luci-app-openclash 2>/dev/null)
elif command -v opkg >/dev/null 2>&1; then
    PKG_ENGINE="opkg"
    openclash_before=$(opkg list-installed luci-app-openclash 2>/dev/null)
else
    echo "未找到支持的包管理器！" >> "$LOGFILE"
    exit 1
fi

echo "使用 $PKG_ENGINE 引擎执行升级..." >> "$LOGFILE"

# 2. 执行升级逻辑
if [ "$PKG_ENGINE" = "apk" ]; then
    apk update >> "$LOGFILE" 2>&1
    apk upgrade >> "$LOGFILE" 2>&1
    openclash_after=$(apk info -v luci-app-openclash 2>/dev/null)
    
elif [ "$PKG_ENGINE" = "opkg" ]; then
    opkg update >> "$LOGFILE" 2>&1
    # opkg 升级安全排雷：跳过系统底层核心和内核模块，防止变砖
    for pkg in $(opkg list-upgradable | awk '{print $1}'); do
        case $pkg in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|opkg|procd|uhttpd)
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                opkg upgrade $pkg >> "$LOGFILE" 2>&1
                ;;
        esac
    done
    openclash_after=$(opkg list-installed luci-app-openclash 2>/dev/null)
fi

# 3. OpenClash 守护联动：如果更新了插件，自动重启服务
if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级 ($openclash_before -> $openclash_after)，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi

echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE

chmod +x files/usr/bin/upg
# 注入定时任务：每 2 天的凌晨 2 点 0 分自动运行升级脚本
echo "0 2 */2 * * /usr/bin/upg" >> files/etc/crontabs/root

# ==========================================
# 5. 编写开机自启网络环境脚本
# ==========================================
cat << 'EOF' > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
exec > /root/setup-network.log 2>&1
set -x

# --- 1. IP与主机名 ---
uci set network.lan.ipaddr='REPLACE_IP_ADDR'
uci set network.lan.netmask='255.255.255.0'
uci set system.@system[0].hostname='Tanxm'

# --- 2. 严格网口分配 (重构级粉碎重建) ---
while uci -q delete network.@device[0]; do :; done

uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'

INTERFACES=$(ls /sys/class/net | grep -E '^e(th|n)' | sort)
INT_COUNT=$(echo "$INTERFACES" | wc -w)

if [ "$INT_COUNT" -gt 1 ]; then
    uci set network.wan=interface
    uci set network.wan.device='eth0'
    uci set network.wan.proto='dhcp'
    
    uci set network.wan6=interface
    uci set network.wan6.device='eth0'
    uci set network.wan6.proto='dhcpv6'
    
    for iface in $INTERFACES; do
        if [ "$iface" != "eth0" ]; then
            uci add_list network.br_lan.ports="$iface"
        fi
    done
else
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
    uci add_list network.br_lan.ports='eth0'
fi
uci set network.lan.device='br-lan'
uci commit network

# --- 3. sda3 智能挂载 (不强制格式化) ---
REAL_UUID=$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "$REAL_UUID" ] && ! uci show fstab | grep -q "$REAL_UUID"; then
    echo "检测到存在 sda3，正在配置开机自动挂载..."
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 4. 优化：BBR, NTP 与 国内源 ---
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

uci delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

if command -v apk >/dev/null 2>&1; then
    if [ -d "/etc/apk/repositories.d" ]; then
        sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
    fi
elif command -v opkg >/dev/null 2>&1; then
    if [ -f "/etc/opkg/distfeeds.conf" ]; then
        sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/opkg/distfeeds.conf 2>/dev/null || true
    fi
fi

rm -f /etc/uci-defaults/99-custom-setup
/etc/init.d/network restart
exit 0
EOF

sed -i "s|REPLACE_IP_ADDR|$IP_ADDR|g" files/etc/uci-defaults/99-custom-setup
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# 6. 云端加速：替换 ImageBuilder 构建源
# ==========================================
echo ">>> 正在优化 ImageBuilder 构建源为腾讯云 (加速拉取)..."
if [ -f "repositories.conf" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.cloud.tencent.com\/immortalwrt/g' repositories.conf
fi
if [ -d "repositories.d" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.cloud.tencent.com\/immortalwrt/g' repositories.d/*.list
fi

# ==========================================
# 7. 模块化定义软件包 (极致纯净 + 性能增强版)
# ==========================================
echo ">>> 定义软件包..."

# 【1. 核心系统与后台界面】
PKG_CORE=(
    "-dnsmasq"                          # 卸载系统自带的简易版 dnsmasq (前面加减号代表卸载)
    "dnsmasq-full"                      # 安装完整版 dnsmasq (支持 IPv6、ipset 等，科学上网必备)
    "luci"                              # OpenWrt/ImmortalWrt 网页后台基础框架
    "luci-base"                         # 网页后台核心依赖库
    "luci-compat"                       # 兼容层库 (确保一些老版本的插件也能正常运行)
    "luci-i18n-base-zh-cn"              # 网页后台基础界面【中文语言包】
    "luci-i18n-firewall-zh-cn"          # 防火墙设置界面【中文语言包】
    "luci-theme-argon"                  # Argon 主题
    "luci-app-openclash"                # OpenClash 科学上网核心插件 (直接从官方源原生编译打包)
    "luci-i18n-package-manager-zh-cn"   # 新版 apk 软件包管理器 (Software菜单)【中文语言包】
)

# 【2. 实用系统工具】
PKG_TOOL=(
    "bash"                              # 强大的命令行终端环境 (替代默认简陋的 ash)
    "curl"                              # 命令行网络请求工具 (下载文件、调试 API 必备)
    "coreutils-nohup"                   # 允许程序在后台挂机运行的工具
    "unzip"                             # ZIP 压缩包解压工具
    "luci-i18n-ttyd-zh-cn"              # 网页版终端界面 (让你直接在浏览器里敲命令行)
    "irqbalance"                        # 多核 CPU 中断负载均衡 (J4125 跑满千兆/2.5G 宽带必备神包)
    "acpid"                             # 高级电源安全断电 (按下物理电源键会“暴力中止”，拦截这硬件信号，然后指挥系统保护数据不丢失)
)

# 【3. 磁盘与文件管理】
PKG_DISK=(
    "blkid"                             # 命令行工具：查看磁盘的 UUID 和文件系统类型
    "lsblk"                             # 命令行工具：以树状图列出所有可用的块设备(磁盘)
    "parted"                            # 强大的命令行磁盘分区工具 (支持大于 2TB 的硬盘)
    "e2fsprogs"                         # Ext2/3/4 文件系统格式化和维护工具集 (mkfs.ext4 依赖它)
    "block-mount"                       # 系统核心组件：负责开机自动挂载磁盘和 Swap 分区
    "luci-i18n-diskman-zh-cn"           # 网页版磁盘管理 UI (可视化分区、格式化、挂载，完全告别命令行)
    "luci-i18n-filemanager-zh-cn"       # 网页版文件浏览器 (可以直接在网页后台上传、下载、修改路由器里的文件)
)

# 【4. 局域网共享与网络增强】
PKG_SHARE=(
    "luci-i18n-ksmbd-zh-cn"             # 现代轻量级网络共享协议 (Samba 的高性能替代品，适合内网看电影)
    "luci-i18n-upnp-zh-cn"              # 自动端口映射服务 (改善 PS5/Switch 游戏主机 NAT 类型，加速 BT/迅雷下载)
    "luci-i18n-wol-zh-cn"               # 局域网唤醒服务 (能在外网一键开机家里的电脑或 NAS)
)

# 【5. OpenClash 底层运行依赖库】(必须全部带上，否则运行报错)
PKG_CLASH_DEPS=(
    "ip-full"                           # 完整版 iproute2 网络配置工具 (OpenClash 策略路由必备)
    "iptables-mod-tproxy"               # iptables 透明代理模块 (OpenClash 流量接管必备)
    "iptables-mod-extra"                # iptables 扩展规则模块
    "kmod-tun"                          # 虚拟隧道网卡驱动 (OpenClash TUN 模式/真全局模式必备)
    "kmod-inet-diag"                    # 网络连接诊断模块 (OpenClash 连接面板监控所需)
    "kmod-tcp-bbr"                      # 拥塞控制算法 (极大提升网络吞吐量和速度，告别网络拥堵)
    "ruby"                              # Ruby 运行环境 (OpenClash 核心脚本使用 Ruby 编写)
    "ruby-yaml"                         # Ruby 的 YAML 库 (用于解析机场订阅配置文件)
    "libcap-bin"                        # 进程权限管理工具 (赋予 OpenClash 必要的网络内核级权限)
    "ca-certificates"                   # 根证书凭据库 (确保 HTTPS 下载订阅和节点测速时不会报 SSL 错误)
)

# 把所有模块的包名拼接到一起
ALL_PKGS=(
    "${PKG_CORE[@]}"
    "${PKG_TOOL[@]}"
    "${PKG_DISK[@]}"
    "${PKG_SHARE[@]}"
    "${PKG_CLASH_DEPS[@]}"
)
PACKAGES="${ALL_PKGS[*]}"
    "libcap-bin"
    "ca-certificates"
)

ALL_PKGS=(
    "${PKG_CORE[@]}"
    "${PKG_TOOL[@]}"
    "${PKG_DISK[@]}"
    "${PKG_SHARE[@]}"
    "${PKG_CLASH_DEPS[@]}"
)
PACKAGES="${ALL_PKGS[*]}"

# ==========================================
# 8. 开始打包
# ==========================================
echo ">>> 正在执行 Make Image 编译..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi"

echo "========== 固件构建圆满完成 =========="
