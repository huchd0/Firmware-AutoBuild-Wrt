#!/bin/bash

# =========================================================
# 0. OpenClash 核心预备
# =========================================================
mkdir -p files/etc/openclash/core
if [ "$APP_OPENCLASH" = "true" ]; then
    echo ">>> 正在下载 OpenClash 兼容版核心..."
    CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
    curl -sL --retry 3 "$CORE_URL" -o meta.tar.gz
    if tar -tzf meta.tar.gz >/dev/null 2>&1; then
        tar -xOzf meta.tar.gz > files/etc/openclash/core/clash_meta
        chmod +x files/etc/openclash/core/clash_meta
        rm -f meta.tar.gz
    fi
fi

# =========================================================
# 1. 初始化脚本 (开机自启核心逻辑)
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"
echo "#!/bin/sh" > $DYNAMIC_SCRIPT

cat >> $DYNAMIC_SCRIPT << EOF
# --- A. 强行锁定 ImmortalWrt 官方纯血软件源 ---
[ -f /etc/opkg/distfeeds.conf ] && sed -i 's|mirrors.vsean.net/openwrt|downloads.immortalwrt.org|g' /etc/opkg/distfeeds.conf
[ -f /etc/apk/repositories ] && sed -i 's|mirrors.vsean.net/openwrt|downloads.immortalwrt.org|g' /etc/apk/repositories

# --- B. 全自动开垦剩余空间并挂载到 /mnt/sda3 ---
if ! lsblk | grep -q sda3; then
    echo -e "n\n3\n\n\nw\n" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then 
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

TARGET_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$TARGET_UUID" ]; then
    uci -q delete fstab.sda3 2>/dev/null || true
    uci set fstab.sda3='mount'
    uci set fstab.sda3.uuid="\$TARGET_UUID"
    uci set fstab.sda3.target='/mnt/sda3'
    uci set fstab.sda3.enabled='1'
    uci set fstab.sda3.fstype='ext4'
    uci commit fstab
    
    mkdir -p /mnt/sda3/collectd_rrd
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# --- C. 数据存储重定向 (Collectd) ---
mkdir -p /mnt/sda3/collectd_rrd
chmod 777 /mnt/sda3/collectd_rrd
uci set luci_statistics.collectd_rrdtool.DataDir='/mnt/sda3/collectd_rrd'
uci commit luci_statistics
/etc/init.d/luci_statistics restart >/dev/null 2>&1 &

# --- D. 智能网络分配逻辑 ---
INTERFACES=\$(ls /sys/class/net 2>/dev/null | grep -E '^eth|^enp|^eno' | sort)
ETH_COUNT=\$(echo "\$INTERFACES" | grep -c '^')
if [ "\$ETH_COUNT" -gt 0 ]; then
    FIRST_ETH=\$(echo "\$INTERFACES" | head -n 1)
    rm -f /etc/config/network
    touch /etc/config/network
    
    uci set network.loopback=interface
    uci set network.loopback.device='lo'
    uci set network.loopback.proto='static'
    uci set network.loopback.ipaddr='127.0.0.1'
    uci set network.loopback.netmask='255.0.0.0'
    
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    
    uci set network.lan=interface
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='$CUSTOM_IP'
    uci set network.lan.netmask='255.255.255.0'
    
    if [ "\$ETH_COUNT" -eq 1 ]; then
        uci add_list network.br_lan.ports="\$FIRST_ETH"
    else
        uci set network.wan=interface
        uci set network.wan.device="\$FIRST_ETH"
        uci set network.wan.proto='dhcp'
        
        uci set network.wan6=interface
        uci set network.wan6.device="\$FIRST_ETH"
        uci set network.wan6.proto='dhcpv6'
        
        for eth in \$(echo "\$INTERFACES" | grep -v "^\$FIRST_ETH\$"); do
            uci add_list network.br_lan.ports="\$eth"
        done
    fi
    uci commit network
fi
EOF

# =========================================================
# 2. 静默预装软件包
# =========================================================
BASE_PACKAGES=""

# 底层核心与证书
BASE_PACKAGES="$BASE_PACKAGES sgdisk nano wget-ssl"             # 分区工具、编辑器、加密下载
BASE_PACKAGES="$BASE_PACKAGES ca-bundle ca-certificates"        # HTTPS 根证书信任库 (必备)
BASE_PACKAGES="$BASE_PACKAGES luci-compat"                      # 兼容旧版 LuCI 插件 (如 OpenClash)

# 硬件驱动与维护
BASE_PACKAGES="$BASE_PACKAGES pciutils usbutils ethtool"        # 查看 PCI/USB 硬件、网卡工具
BASE_PACKAGES="$BASE_PACKAGES iperf3 irqbalance"                # 网速测试、多核中断平衡
BASE_PACKAGES="$BASE_PACKAGES kmod-vmxnet3"                     # 虚拟机网卡驱动支持
BASE_PACKAGES="$BASE_PACKAGES e2fsprogs fdisk"                  # ext4 格式化与分区操作 (sda3 开荒必备)

# 基础 UI 管理
BASE_PACKAGES="$BASE_PACKAGES luci-app-package-manager luci-i18n-package-manager-zh-cn" # 软件包中心
BASE_PACKAGES="$BASE_PACKAGES luci-app-ttyd luci-i18n-ttyd-zh-cn"                       # 网页 SSH 终端

# 状态监控 (数据重定向至 sda3)
BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn"           # 统计图表界面
BASE_PACKAGES="$BASE_PACKAGES collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory" # 监控采集引擎

# =========================================================
# 3. 动态加载 UI 勾选的插件 (按功能严格分类)
# =========================================================

# 🌐 科学上网 & 代理路由
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_PASSWALL" = "true" ]  && BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"

# 🌍 VPN & 内网穿透组网
[ "$APP_WIREGUARD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-proto-wireguard"
[ "$APP_TAILSCALE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES tailscale"
[ "$APP_ZEROTIER" = "true" ]  && BASE_PACKAGES="$BASE_PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn"

# 💾 NAS 存储 & 下载工具
[ "$APP_DISKMAN" = "true" ]   && BASE_PACKAGES="$BASE_PACKAGES luci-app-diskman luci-i18n-diskman-zh-cn"
[ "$APP_KSMBD" = "true" ]     && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
[ "$APP_ALIST" = "true" ]     && BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"
[ "$APP_QBITTORRENT" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"

# 🛠️ 系统增强 & 实用工具
[ "$INCLUDE_DOCKER" = "true" ]  && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"
[ "$APP_ADGUARDHOME" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-adguardhome"
[ "$APP_WECHATPUSH" = "true" ]  && BASE_PACKAGES="$BASE_PACKAGES luci-app-wechatpush luci-i18n-wechatpush-zh-cn"

# 🎨 主题 UI
[ "$THEME_ARGON" = "true" ]     && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"

# 🔌 整合版网卡驱动合集 (Intel / Realtek)
[ "$KMOD_INTEL" = "true" ]      && BASE_PACKAGES="$BASE_PACKAGES kmod-e1000e kmod-igc kmod-ixgbe"
[ "$KMOD_REALTEK" = "true" ]    && BASE_PACKAGES="$BASE_PACKAGES kmod-r8169 kmod-r8125 kmod-r8126 kmod-r8152 kmod-r8153"

# =========================================================
# 4. 极限打包
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

# 暴力清坏源
find . -type f \( -name "repositories*" -o -name "distfeeds.conf" \) -exec sed -i 's|mirrors.vsean.net/openwrt|downloads.immortalwrt.org|g' {} + 2>/dev/null || true

sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_SIZE}/g" .config || echo "CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_SIZE}" >> .config
sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config || echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config

echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y" >> .config
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config   
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
