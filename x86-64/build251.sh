#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
    MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

echo ">>> 1. 自定义固件参数 <<<"
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

echo ">>> 2. 准备初始化文件夹 <<<"
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/openclash/core

# 我们不需要手动下载 OpenClash 和 Argon 的安装包了，ImmortalWrt 自带！
# 只需要提前帮它下好 Meta 兼容版内核即可：
echo "正在下载 OpenClash Meta 兼容版内核..."
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

echo ">>> 4. 编写全自动开机初始化脚本 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- A. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

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

# --- C. 智能大分区挂载保护 ---
if ! lsblk | grep -q sda3; then
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || block info >/dev/null 2>&1 || true
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
    mount /dev/sda3 /mnt/sda3 2>/dev/null || block mount
fi

# --- D. 基础性能监控配置 ---
if [ -x "/etc/init.d/collectd" ]; then
    [ ! -f "/etc/config/luci_statistics" ] && touch /etc/config/luci_statistics
    uci set luci_statistics.collectd.enable='1'
    
    mkdir -p /mnt/sda3/collectd_rrd
    uci set luci_statistics.collectd_rrdtool=statistics
    uci set luci_statistics.collectd_rrdtool.enable='1'
    uci set luci_statistics.collectd_rrdtool.DataDir='/mnt/sda3/collectd_rrd'

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
fi

# --- E. 守护进程：强制修改统一 SSID 并开机启动 Wi-Fi ---
cat << 'WATCHER' > /etc/init.d/wifi-watcher
#!/bin/sh /etc/rc.common
START=99

start() {
    (
        for i in \$(seq 1 20); do
            if uci show wireless | grep -q "=wifi-device"; then
                break
            fi
            wifi config
            sleep 3
        done
        
        for radio in \$(uci show wireless | grep '=wifi-device' | cut -d'.' -f2 | cut -d'=' -f1); do
            uci set wireless.\${radio}.disabled='0'
            
            for iface in \$(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
                if [ "\$(uci get wireless.\${iface}.device)" = "\${radio}" ]; then
                    uci set wireless.\${iface}.ssid='mywifi7'
                    uci set wireless.\${iface}.encryption='sae-mixed'
                    uci set wireless.\${iface}.key='Aa666666'
                    uci set wireless.\${iface}.ieee80211w='1'
                    uci set wireless.\${iface}.network='lan'
                    uci set wireless.\${iface}.mode='ap'
                fi
            done
        done
        
        uci commit wireless
        wifi reload
        
        sleep 5
        /etc/init.d/luci_statistics restart
        /etc/init.d/collectd restart
        
        /etc/init.d/wifi-watcher disable
        rm -f /etc/init.d/wifi-watcher
    ) &
}
WATCHER

chmod +x /etc/init.d/wifi-watcher
/etc/init.d/wifi-watcher enable

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 配置 ImmortalWrt 官方软件列表 <<<"

# 因为换成了 ImmortalWrt，这里直接写 luci-app-openclash 和 luci-theme-argon 就能完美打包！
PKG_CORE="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn"
PKG_DISK="block-mount blkid lsblk parted fdisk e2fsprogs kmod-usb-storage kmod-usb-storage-uas kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat kmod-fs-exfat"
PKG_DEPENDS="coreutils-nohup coreutils-base64 coreutils-sort bash jq curl ca-bundle libcap libcap-bin ruby ruby-yaml unzip"
PKG_NETWORK="ip-full iptables-mod-tproxy iptables-mod-extra kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-igc kmod-igb kmod-r8169 iwinfo"
PKG_WIFI_BT="-wpad-basic-mbedtls -wpad-basic-wolfssl wpad-openssl kmod-mt7925e kmod-mt7925-firmware kmod-btusb bluez-daemon kmod-input-uinput"
PKG_MONITOR="nano htop ethtool tcpdump mtr conntrack iftop screen collectd-mod-thermal collectd-mod-sensors collectd-mod-cpu collectd-mod-ping collectd-mod-interface collectd-mod-rrdtool collectd-mod-iwinfo"
PKG_LUCI_APPS="luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd luci-i18n-ksmbd-zh-cn luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn luci-app-statistics luci-i18n-statistics-zh-cn luci-app-openclash luci-theme-argon"

PACKAGES="$PKG_CORE $PKG_DISK $PKG_DEPENDS $PKG_NETWORK $PKG_WIFI_BT $PKG_MONITOR $PKG_LUCI_APPS"

echo ">>> 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已圆满完成！ <<<"
