#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-yes}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
    MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

echo "=== 1. 自定义固件参数 (互刷保护) ==="
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

# 极致优化：只生成 UEFI 的 squashfs 格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

echo "=== 2. 准备初始化文件夹 ==="
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/init.d
mkdir -p files/usr/bin
mkdir -p files/etc/crontabs

echo "=== 3. 下载必要核心与驱动固件 ==="

echo "正在下载 OpenClash Meta 兼容版内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

echo "正在注入 MT7925 官方底层固件..."
mkdir -p files/lib/firmware/mediatek/mt7925

wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin"

echo "=== 4. 编写全自动开机初始化脚本 ==="

cat << 'EOF_WIFI' > files/etc/init.d/wifi-auto-patch
#!/bin/sh /etc/rc.common
START=99

start() {
    # 将探测和修改逻辑放进后台 ( ) & 执行，绝对不阻塞路由器开机速度
    (
        WAIT=0
        while [ $WAIT -lt 30 ]; do
            wifi config
            if uci get wireless.radio0 >/dev/null 2>&1; then
                break
            fi
            sleep 2
            WAIT=$((WAIT+1))
        done

        if uci get wireless.radio0 >/dev/null 2>&1; then
            uci set wireless.radio0.band='5g'
            uci set wireless.radio0.channel='149'
            uci set wireless.radio0.htmode='EHT80'
            uci set wireless.radio0.country='AU'
            uci set wireless.radio0.cell_density='0'
            uci set wireless.radio0.txpower='23'
            
            for iface in $(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
                uci set wireless.${iface}.ssid='mywifi7'
                uci set wireless.${iface}.encryption='sae-mixed'
                uci set wireless.${iface}.key='Aa666666'
                uci set wireless.${iface}.ieee80211w='1'
                uci set wireless.${iface}.network='lan'
                uci set wireless.${iface}.mode='ap'
            done
            
            uci commit wireless
            
            # 【核心修复】强制重启无线服务，让 mywifi7 立刻生效！
            sleep 2
            wifi reload
        fi
        
        # 任务完成，自我销毁
        rm -f /etc/init.d/wifi-auto-patch
    ) &
}
EOF_WIFI
chmod +x files/etc/init.d/wifi-auto-patch


cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 开启 Wi-Fi 智能补全服务
/etc/init.d/wifi-auto-patch enable

# --- A1. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# --- A2. 强行设置时区与主机名 ---
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# --- B. 智能网口分配逻辑 ---
INTERFACES=\$(ls /sys/class/net | grep -E '^eth[0-9]+' | sort)
PORT_COUNT=\$(echo "\$INTERFACES" | wc -w)

if [ "\$PORT_COUNT" -eq 1 ]; then
    uci add_list network.@device[0].ports='eth0'
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
else
    for iface in \$INTERFACES; do
        if [ "\$iface" = "eth0" ]; then
            uci set network.wan='interface'
            uci set network.wan.proto='dhcp'
            uci set network.wan.device='eth0'
            uci set network.wan6='interface'
            uci set network.wan6.proto='dhcpv6'
            uci set network.wan6.device='eth0'
        else
            uci add_list network.@device[0].ports="\$iface" 
        fi
    done
fi
uci commit network

# --- C. 智能大分区强制挂载保护 ---
if ! lsblk | grep -q sda3; then
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

TARGET_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$TARGET_UUID" ]; then
    echo "config 'global'" > /etc/config/fstab
    echo "  option  anon_swap   '0'" >> /etc/config/fstab
    echo "  option  anon_mount  '0'" >> /etc/config/fstab
    echo "  option  auto_swap   '1'" >> /etc/config/fstab
    echo "  option  auto_mount  '1'" >> /etc/config/fstab
    echo "  option  delay_root  '5'" >> /etc/config/fstab
    echo "  option  check_fs    '0'" >> /etc/config/fstab
    
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$TARGET_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
    
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# --- D. 性能监控图表修复 ---
if [ -x "/etc/init.d/collectd" ] && [ ! -f "/etc/collectd_inited" ]; then
    
    [ ! -f "/etc/config/luci_statistics" ] && touch /etc/config/luci_statistics
    
    uci set luci_statistics.collectd=statistics
    uci set luci_statistics.collectd.BaseDir='/var/run/collectd'
    uci set luci_statistics.collectd.Include='/etc/collectd/conf.d'
    uci set luci_statistics.collectd.PIDFile='/var/run/collectd.pid'
    uci set luci_statistics.collectd.PluginDir='/usr/lib/collectd'
    uci set luci_statistics.collectd.TypesDB='/usr/share/collectd/types.db'
    uci set luci_statistics.collectd.Interval='30'
    uci set luci_statistics.collectd.ReadThreads='2'
    uci set luci_statistics.collectd.enable='1'
    
    uci del luci_statistics.collectd_network.enable 2>/dev/null || true
    uci set luci_statistics.collectd_mqtt=statistics

    if [ -d "/mnt/sda3/" ]; then
        mkdir -p /mnt/sda3/collectd_rrd
        chmod -R 777 /mnt/sda3/collectd_rrd
        uci set luci_statistics.collectd_rrdtool=statistics
        uci set luci_statistics.collectd_rrdtool.enable='1'
        uci set luci_statistics.collectd_rrdtool.DataDir='/mnt/sda3/collectd_rrd'
    fi

    uci set luci_statistics.collectd_thermal=statistics
    uci set luci_statistics.collectd_thermal.enable='1'
    uci set luci_statistics.collectd_sensors=statistics
    uci set luci_statistics.collectd_sensors.enable='1'
    uci set luci_statistics.collectd_interface=statistics
    uci set luci_statistics.collectd_interface.enable='1'
    uci set luci_statistics.collectd_interface.ignoreselected='0'
    uci set luci_statistics.collectd_cpu=statistics
    uci set luci_statistics.collectd_cpu.enable='1'
    
    uci set luci_statistics.collectd_ping=statistics
    uci set luci_statistics.collectd_ping.enable='1'
    uci delete luci_statistics.collectd_ping.Hosts 2>/dev/null
    uci add_list luci_statistics.collectd_ping.Hosts='114.114.114.114'
    uci add_list luci_statistics.collectd_ping.Hosts='8.8.8.8'

    uci commit luci_statistics
    
    /etc/init.d/luci_statistics enable
    /etc/init.d/luci_statistics restart
    /etc/init.d/collectd enable
    /etc/init.d/collectd restart
    
    touch /etc/collectd_inited
fi

# --- D2. Docker 自动化网络互通配置 ---
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    [ ! -f "/etc/config/dockerd" ] && touch /etc/config/dockerd
    uci set dockerd.globals=globals
    uci set dockerd.globals.data_root='/mnt/sda3/docker'
    uci commit dockerd

    uci add firewall zone
    uci set firewall.@zone[-1].name='docker'
    uci set firewall.@zone[-1].network='docker0'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'

    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='docker'
    uci set firewall.@forwarding[-1].dest='lan'

    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='docker'

    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='docker'
    uci set firewall.@forwarding[-1].dest='wan'
    
    uci commit firewall
fi

if uci get luci.themes.Argon >/dev/null 2>&1; then
    uci set luci.main.mediaurlbase='/luci-static/argon'
    uci commit luci
fi

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup


# ==========================================
# --- E. 终端神器 ttyd 联网自动补装 ---
# ==========================================
cat << 'EOF_TTYD' > files/etc/init.d/install-ttyd
#!/bin/sh /etc/rc.common
START=99
start() {
    WAIT_NET=0
    while [ $WAIT_NET -lt 60 ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            apk update
            apk add luci-app-ttyd luci-i18n-ttyd-zh-cn
            rm -f /etc/init.d/install-ttyd
            break
        fi
        sleep 5
        WAIT_NET=$((WAIT_NET+1))
    done
}
EOF_TTYD
chmod +x files/etc/init.d/install-ttyd
mkdir -p files/etc/rc.d
ln -s ../init.d/install-ttyd files/etc/rc.d/S99install-ttyd


# ==========================================
# --- F. 优雅内置：全自动静默升级与定时任务 ---
# ==========================================
echo "正在生成自动升级脚本与定时任务..."

# 1. 自动生成极简命令放入系统目录 (/usr/bin/upg)
cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
# upg - 自动静默升级软件包，安全守护
LOGFILE="/root/upg.log"

# 控制日志大小：如果日志超过 1MB，就清空重建，防止撑爆存储
if [ -f "\$LOGFILE" ] && [ \$(wc -c < "\$LOGFILE") -gt 1048576 ]; then
    echo "日志过大，已清空重建" > "\$LOGFILE"
fi

echo "===== Auto Upgrade Start: \$(date) =====" >> "\$LOGFILE"

if opkg list-installed | grep -q '^openclash '; then
    openclash_before=\$(opkg list-installed | grep '^openclash ' | awk '{print \$2}')
else
    openclash_before=""
fi

opkg update >> "\$LOGFILE" 2>&1

for pkg in \$(opkg list-upgradable | awk '{print \$1}'); do
    case \$pkg in
        base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|opkg|procd|uhttpd)
            # 核心系统组件绝对不升级，保障路由不死机
            ;;
        *)
            echo "升级: \$pkg" >> "\$LOGFILE"
            opkg upgrade \$pkg >> "\$LOGFILE" 2>&1
            ;;
    esac
done

if [ -n "\$openclash_before" ]; then
    openclash_after=\$(opkg list-installed | grep '^openclash ' | awk '{print \$2}')
    if [ "\$openclash_before" != "\$openclash_after" ]; then
        echo "OpenClash 已升级 (\$openclash_before -> \$openclash_after)，重启服务..." >> "\$LOGFILE"
        /etc/init.d/openclash restart >> "\$LOGFILE" 2>&1
    fi
fi

echo "===== Auto Upgrade End: \$(date) =====" >> "\$LOGFILE"
EOF_UPGRADE

# 2. 赋予可执行权限
chmod +x files/usr/bin/upg

# 3. 写入 Cron 定时任务 (隔天凌晨 2 点自动执行)
echo "0 2 */2 * * /usr/bin/upg" >> files/etc/crontabs/root


echo "=== 5. 配置 ImmortalWrt 专属软件列表 ==="

PKG_CORE=(
    "-dnsmasq"
    "-dnsmasq-default"
    "dnsmasq-full"
    "luci"
    "luci-base"
    "luci-compat"
    "luci-i18n-base-zh-cn"
    "luci-i18n-firewall-zh-cn"
    "luci-i18n-package-manager-zh-cn"
)

PKG_DISK=(
    "block-mount"
    "blkid"
    "lsblk"
    "fdisk"
    "e2fsprogs"
    "kmod-usb-storage"
    "kmod-usb-storage-uas"
    "kmod-fs-ext4"
    "kmod-fs-ntfs3"
    "kmod-fs-vfat"
    "kmod-fs-exfat"
)

PKG_DEPENDS=(
    "coreutils-nohup"
    "bash"
    "jq"
    "curl"
    "ca-bundle"
    "libcap"
    "libcap-bin"
    "ruby"
    "ruby-yaml"
    "unzip"
)

PKG_NETWORK=(
    "ip-full"
    "iptables-mod-tproxy"
    "iptables-mod-extra"
    "kmod-tun"
    "kmod-inet-diag"
    "kmod-nft-tproxy"
    "kmod-igc"
    "kmod-igb"
    "kmod-r8169"
    "iwinfo"
    "kmod-tcp-bbr"
)

PKG_WIFI_BT=(
    "-wpad"
    "-wpad-basic"
    "-wpad-basic-mbedtls"
    "-wpad-basic-wolfssl"
    "-wpad-mbedtls"
    "-wpad-wolfssl"
    "wpad-openssl"
    "kmod-mt7925e"
    "kmod-mt7925-firmware"
    "kmod-btusb"
    "bluez-daemon"
    "kmod-input-uinput"
)

PKG_MONITOR=(
    "nano"
    "htop"
    "ethtool"
    "tcpdump"
    "mtr"
    "conntrack"
    "iftop"
    "screen"
    "collectd-mod-thermal"
    "collectd-mod-sensors"
    "collectd-mod-cpu"
    "collectd-mod-ping"
    "collectd-mod-interface"
    "collectd-mod-rrdtool"
    "collectd-mod-iwinfo"
)

PKG_HW_TOOLS=(
    "pciutils"
    "iperf3"
    "intel-microcode"
)

PKG_LUCI_APPS=(
    "luci-app-openclash"
    "luci-app-homeproxy"
    "luci-i18n-homeproxy-zh-cn"
    "luci-theme-argon"
    "luci-app-ksmbd"
    "luci-i18n-ksmbd-zh-cn"
    "luci-app-statistics"
    "luci-i18n-statistics-zh-cn"
    "luci-app-autoreboot"
    "luci-i18n-autoreboot-zh-cn"
)

# 动态加载 Docker 包
PKG_DOCKER=()
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PKG_DOCKER=(
        "dockerd"
        "docker-compose"
        "luci-app-dockerman"
        "luci-i18n-dockerman-zh-cn"
    )
fi

ALL_PKGS=(
    "${PKG_CORE[@]}"
    "${PKG_DISK[@]}"
    "${PKG_DEPENDS[@]}"
    "${PKG_NETWORK[@]}"
    "${PKG_WIFI_BT[@]}"
    "${PKG_MONITOR[@]}"
    "${PKG_HW_TOOLS[@]}"
    "${PKG_LUCI_APPS[@]}"
    "${PKG_DOCKER[@]}"
)

PACKAGES="${ALL_PKGS[*]}"

echo "=== 6. 开始 Make Image 打包 ==="
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo "=== 7. 提取固件 ==="
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo "=== 全部构建任务已圆满完成！ ==="
