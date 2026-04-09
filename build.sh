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

# 极致优化：只生成 UEFI 的 squashfs 格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

echo ">>> 2. 准备初始化文件夹 <<<"
mkdir -p files/root
mkdir -p files/etc/uci-defaults

echo ">>> 3. 下载 OpenClash Meta 核心 <<<"
# OpenClash 的 Meta 核心依然需要，保留下载
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

# 🚨【核心排雷】：已彻底删除 wget 下载 MT7925 .bin 的代码！
# 必须让系统使用官方纯净驱动，否则网卡在开机时会假死！

echo ">>> 4. 编写全自动开机初始化脚本 <<<"

cat << 'EOF' > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- A. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# --- B. 智能网口分配逻辑 ---
INTERFACES=$(ls /sys/class/net | grep -E '^eth[0-9]+' | sort)
PORT_COUNT=$(echo "$INTERFACES" | wc -w)

if [ "$PORT_COUNT" -eq 1 ]; then
    uci add_list network.@device[0].ports='eth0'
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
else
    for iface in $INTERFACES; do
        if [ "$iface" = "eth0" ]; then
            uci set network.wan='interface'
            uci set network.wan.proto='dhcp'
            uci set network.wan.device='eth0'
            uci set network.wan6='interface'
            uci set network.wan6.proto='dhcpv6'
            uci set network.wan6.device='eth0'
        else
            uci add_list network.@device[0].ports="$iface" 
        fi
    done
fi
uci commit network

# --- C. 智能大分区挂载与图表目录预设 ---
if ! lsblk | grep -q sda3; then
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

TARGET_UUID=$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "$TARGET_UUID" ]; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="$TARGET_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
    
    # 强制挂载并赋予最高权限，确保图表服务绝对能写入
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
    mkdir -p /mnt/sda3/collectd_rrd
    chmod -R 777 /mnt/sda3/collectd_rrd
fi

# --- D. 图表服务基础配置写入 ---
[ ! -f "/etc/config/luci_statistics" ] && touch /etc/config/luci_statistics
uci set luci_statistics.collectd=statistics
uci set luci_statistics.collectd.enable='1'
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

# --- E. 终极大招：利用系统异步任务，优雅拉起 Wi-Fi 和图表 ---
# 我们生成一个只需执行一次的延迟脚本，并在后台运行
cat << 'STARTUP_SCRIPT' > /tmp/startup_delay.sh
#!/bin/sh
# 睡 15 秒，等系统所有硬件（包括那个傲娇的 MT7925 网卡）全部通电完毕
sleep 15

# 强制系统自动探测并生成最新的网卡路径配置（不用再写死 PCI 路径）
rm -f /etc/config/wireless
wifi config
sleep 2

# 如果探测到了网卡，覆盖我们的专属配置
if uci show wireless | grep -q 'wifi-device'; then
    for radio in $(uci show wireless | grep '=wifi-device' | cut -d'.' -f2 | cut -d'=' -f1); do
        uci set wireless.${radio}.disabled='0'
        uci set wireless.${radio}.country='AU'
    done
    
    for iface in $(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
        uci set wireless.${iface}.ssid='mywifi7'
        uci set wireless.${iface}.encryption='sae-mixed'
        uci set wireless.${iface}.key='Aa666666'
        uci set wireless.${iface}.ieee80211w='1'
    done
    
    uci commit wireless
    wifi reload
fi

# 在一切网络和 Wi-Fi 就绪后，最后重启图表服务，确保它能抓到所有的网卡
sleep 3
/etc/init.d/luci_statistics restart
/etc/init.d/collectd restart
STARTUP_SCRIPT

chmod +x /tmp/startup_delay.sh
# 将脚本推入后台执行，不阻塞当前的 uci-defaults 流程
/tmp/startup_delay.sh &

# 替换软件源为国内源
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 配置官方软件列表 <<<"

PKG_CORE="-dnsmasq dnsmasq-full \
luci luci-base luci-compat \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn"

PKG_DISK="block-mount blkid lsblk parted fdisk e2fsprogs \
kmod-usb-storage kmod-usb-storage-uas \
kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat kmod-fs-exfat"

PKG_DEPENDS="coreutils-nohup coreutils-base64 coreutils-sort bash jq curl ca-bundle \
libcap libcap-bin ruby ruby-yaml unzip"

PKG_NETWORK="ip-full iptables-mod-tproxy iptables-mod-extra kmod-tun kmod-inet-diag \
kmod-nft-tproxy \
kmod-igc kmod-igb kmod-r8169 \
iwinfo"

PKG_WIFI_BT="-wpad-basic-mbedtls -wpad-basic-wolfssl wpad-openssl \
kmod-mt7925e kmod-mt7925-firmware \
kmod-btusb bluez-daemon kmod-input-uinput"

PKG_MONITOR="nano htop ethtool tcpdump mtr conntrack iftop screen \
collectd-mod-thermal collectd-mod-sensors collectd-mod-cpu collectd-mod-ping collectd-mod-interface collectd-mod-rrdtool collectd-mod-iwinfo"

PKG_LUCI_APPS="luci-app-ttyd luci-i18n-ttyd-zh-cn \
luci-app-ksmbd luci-i18n-ksmbd-zh-cn \
luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn \
luci-app-statistics luci-i18n-statistics-zh-cn \
luci-app-openclash luci-theme-argon"

PACKAGES="$PKG_CORE $PKG_DISK $PKG_DEPENDS $PKG_NETWORK $PKG_WIFI_BT $PKG_MONITOR $PKG_LUCI_APPS"

echo ">>> 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已圆满完成！ <<<"
