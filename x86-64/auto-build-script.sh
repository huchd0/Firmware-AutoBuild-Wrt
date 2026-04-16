#!/bin/bash

# =========================================================
# 0. 云端预处理：OpenClash 核心预备
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

# --- B. 🌟 吸收你的绝招：全自动开垦剩余空间并挂载到 /opt ---
if ! lsblk | grep -q sda3; then
    # 模拟键盘按键，自动新建 sda3 吃满剩余空间
    echo -e "n\n3\n\n\nw\n" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then 
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

TARGET_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$TARGET_UUID" ]; then
    # 写入 fstab，强行挂载到 /opt
    uci -q delete fstab.opt 2>/dev/null || true
    uci set fstab.opt='mount'
    uci set fstab.opt.uuid="\$TARGET_UUID"
    uci set fstab.opt.target='/opt'
    uci set fstab.opt.enabled='1'
    uci set fstab.opt.fstype='ext4'
    uci commit fstab
    
    mkdir -p /opt/collectd_rrd
    mount /dev/sda3 /opt 2>/dev/null || true
fi

# --- C. 数据存储重定向 (Collectd) ---
# 确保挂载成功后再重定向路径
mkdir -p /opt/collectd_rrd
chmod 777 /opt/collectd_rrd
uci set statistics.collectd.Datadir='/opt/collectd_rrd'
uci commit statistics
/etc/init.d/collectd restart >/dev/null 2>&1 &

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
# 2. 静默预装软件包 (精准适配)
# =========================================================
BASE_PACKAGES=""

# 核心底层增强工具 (加入 e2fsprogs 确保格式化 sda3 成功)
BASE_PACKAGES="$BASE_PACKAGES sgdisk nano wget-ssl luci-compat e2fsprogs fdisk"
BASE_PACKAGES="$BASE_PACKAGES pciutils usbutils ethtool iperf3 irqbalance kmod-vmxnet3"

# 🌟 找回失落的中文：使用 25.12 唯一正统的软件中心包名
BASE_PACKAGES="$BASE_PACKAGES luci-app-package-manager luci-i18n-package-manager-zh-cn"

# 状态监控包 (收集数据到 /opt)
BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory"

# =========================================================
# 3. 动态加载 UI 勾选的大插件
# =========================================================
[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_PASSWALL" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"
[ "$APP_KSMBD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
[ "$APP_ADGUARDHOME" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-adguardhome"
[ "$APP_ALIST" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"
[ "$APP_QBITTORRENT" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"
[ "$APP_MWAN3" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-mwan3 luci-i18n-mwan3-zh-cn"
[ "$APP_VLMCSD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-vlmcsd luci-i18n-vlmcsd-zh-cn"
[ "$APP_SQM" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-sqm luci-i18n-sqm-zh-cn"
[ "$APP_WIREGUARD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-proto-wireguard"
[ "$APP_TAILSCALE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES tailscale"
[ "$APP_ZEROTIER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn"
[ "$APP_FRPC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-frpc luci-i18n-frpc-zh-cn"

[ "$KMOD_IGC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-igc"
[ "$KMOD_IXGBE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-ixgbe"
[ "$KMOD_E1000E" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-e1000e"
[ "$KMOD_R8169" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-r8169"
[ "$KMOD_R8125" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-r8125"
[ "$INCLUDE_DOCKER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"

# =========================================================
# 4. 极限打包前置修复与直出
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

# 🌟 降维打击源修正：全局搜索替换所有配置内的坏源！
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
