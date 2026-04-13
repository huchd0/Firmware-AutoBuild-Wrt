#!/bin/bash
set -e

echo "========== 开始 GitHub 极速纯净版构建 =========="

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

# 强制禁用不必要的格式，大幅度缩短编译时间，避免 I/O 爆炸
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

# ==========================================
# 3. 极速拉取 OpenClash (云端预处理)
# ==========================================
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core files/etc/config

echo ">>> 正在拉取 OpenClash 插件与 Meta 核心..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

META_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
wget -qO- "$META_CORE_URL" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta

# ==========================================
# 4. 底层网络配置强制注入 (防崩保障)
# ==========================================
cat << EOF > files/etc/config/network
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fdc9:e120:3917::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '$IP_ADDR'
	option netmask '255.255.255.0'
EOF

# ==========================================
# 5. 编写开机自启脚本
# ==========================================
cat << 'EOF' > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
exec > /root/setup-network.log 2>&1
set -x

# --- 1. IP与主机名 ---
uci set network.lan.ipaddr='REPLACE_IP_ADDR'
uci set network.lan.netmask='255.255.255.0'
uci set system.@system[0].hostname='Tanxm'

# --- 2. 网口分配 (eth0=WAN, 其余=LAN) ---
INTERFACES=$(ls /sys/class/net | grep -E '^e(th|n)' | sort)
INT_COUNT=$(echo "$INTERFACES" | wc -w)

uci del_list network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'

if [ "$INT_COUNT" -gt 1 ]; then
    uci set network.wan=interface
    uci set network.wan.device='eth0'
    uci set network.wan.proto='dhcp'
    uci set network.wan6=interface
    uci set network.wan6.device='eth0'
    uci set network.wan6.proto='dhcpv6'
    for iface in $INTERFACES; do
        [ "$iface" != "eth0" ] && uci add_list network.@device[0].ports="$iface"
    done
else
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
    uci add_list network.@device[0].ports='eth0'
fi
uci commit network

# --- 3. sda3 智能挂载 (不再执行 fdisk 和 mkfs) ---
REAL_UUID=$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "$REAL_UUID" ] && ! uci show fstab | grep -q "$REAL_UUID"; then
    echo "检测到存在 sda3，正在配置开机自动挂载..."
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 4. BBR 与 NTP 优化 ---
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

uci delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# --- 5. 纯离线安装预置插件 ---
if [ -f "/root/luci-app-openclash.ipk" ]; then
    opkg install /root/luci-app-openclash.ipk
    rm -f /root/luci-app-openclash.ipk
fi

rm -f /etc/uci-defaults/99-custom-setup
/etc/init.d/network restart
exit 0
EOF

sed -i "s|REPLACE_IP_ADDR|$IP_ADDR|g" files/etc/uci-defaults/99-custom-setup
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# 6. 模块化定义软件包 (简单纯净版)
# ==========================================
echo ">>> 定义软件包..."

PKG_CORE=(
    "-dnsmasq"
    "dnsmasq-full"
    "luci"
    "luci-base"
    "luci-compat"
    "luci-i18n-base-zh-cn"
    "luci-i18n-firewall-zh-cn"
    "luci-theme-argon"
)

PKG_TOOL=(
    "bash"
    "curl"
    "coreutils-nohup"
    "unzip"
    "luci-i18n-ttyd-zh-cn" # 终端工具
)

PKG_DISK=(
    "blkid"
    "lsblk"
    "parted"
    "fdisk"
    "e2fsprogs"            # ext4 格式化工具
    "block-mount"
    "luci-i18n-diskman-zh-cn"     # 磁盘管理 UI
    "luci-i18n-filemanager-zh-cn" # 文件管理 UI
)

PKG_SHARE=(
    "luci-i18n-ksmbd-zh-cn" # 轻量级网络共享
)

PKG_CLASH_DEPS=(
    "ip-full"
    "iptables-mod-tproxy"
    "iptables-mod-extra"
    "kmod-tun"
    "kmod-inet-diag"
    "kmod-tcp-bbr"
    "ruby"
    "ruby-yaml"
    "libcap-bin"
    "ca-certificates"
)

# 组合所有软件包
ALL_PKGS=(
    "${PKG_CORE[@]}"
    "${PKG_TOOL[@]}"
    "${PKG_DISK[@]}"
    "${PKG_SHARE[@]}"
    "${PKG_CLASH_DEPS[@]}"
)
PACKAGES="${ALL_PKGS[*]}"

# ==========================================
# 7. 开始打包
# ==========================================
echo ">>> 正在执行 Make Image 编译..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi"

echo "========== 固件构建圆满完成 =========="
