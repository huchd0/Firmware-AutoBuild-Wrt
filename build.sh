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
mkdir -p files/etc/init.d

echo ">>> 3. 下载第三方 APK 插件与 OpenClash 核心 <<<"
OPENCLASH_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
if [ -n "$OPENCLASH_URL" ]; then
    wget -qO files/root/luci-app-openclash.apk "$OPENCLASH_URL"
fi

ARGON_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
if [ -n "$ARGON_URL" ]; then
    wget -qO files/root/luci-theme-argon.apk "$ARGON_URL"
fi

echo "正在下载 OpenClash Meta 兼容版内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

echo "正在注入 MT7925 官方底层固件..."
mkdir -p files/lib/firmware/mediatek/mt7925
wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin \
"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin \
"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin \
"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin"


echo ">>> 4. 编写全自动开机初始化脚本 <<<"

# ===================================================================
# --- 核心大招：利用 rc.local 压轴出场，彻底解决图表和 Wi-Fi 抓取 ---
# ===================================================================
cat << 'EOF' > files/etc/rc.local
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

if [ ! -f "/etc/firstboot_custom_done" ]; then
    # 1. 睡 10 秒，等系统彻底安顿好
    sleep 10

    # 2. 【智能 Wi-Fi 注入】：让系统自己抓硬件路径，我们只管改参数！
    rm -f /etc/config/wireless
    wifi config
    sleep 2
    
    if uci get wireless.radio0 >/dev/null 2>&1; then
        # 保持系统抓到的 path 和 type 不变，注入你的专属参数
        uci set wireless.radio0.disabled='1' # 默认关闭，等你手动去点
        uci set wireless.radio0.band='5g'
        uci set wireless.radio0.channel='149'
        uci set wireless.radio0.htmode='EHT80'
        uci set wireless.radio0.country='AU'
        uci set wireless.radio0.cell_density='0'
        uci set wireless.radio0.txpower='23'
        
        if uci get wireless.default_radio0 >/dev/null 2>&1; then
            uci set wireless.default_radio0.ssid='mywifi7'
            uci set wireless.default_radio0.encryption='sae-mixed'
            uci set wireless.default_radio0.key='Aa666666'
            # WPA3 必须开启管理帧保护，否则开启直接报错
            uci set wireless.default_radio0.ieee80211w='1'
        fi
        uci commit wireless
        wifi reload
    fi

    # 3. 【暴力赋权】：确保大硬盘目录绝对可写
    if [ -d "/mnt/sda3" ]; then
        mkdir -p /mnt/sda3/collectd_rrd
        chmod -R 777 /mnt/sda3/collectd_rrd
    fi

    # 4. 【破壁之手】：万事俱备，最后模拟你在网页点“保存并应用”！
    # 强制翻译底层配置并拉起画图引擎
    /etc/init.d/luci_statistics restart
    /etc/init.d/collectd restart

    touch /etc/firstboot_custom_done
fi

exit 0
EOF
chmod +x files/etc/rc.local


# ===================================================================
# --- 基础配置设定 (网络、挂载、图表规则) ---
# ===================================================================
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 1. 核心网络设置
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# 时区设定为中国，防止图表时间线错乱
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 2. 智能网口分配逻辑
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

# 3. 智能大分区挂载
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
    
    # 立刻挂载，给图表备好硬盘
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# 4. 图表统计底层参数埋入
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
uci del luci_statistics.collectd_network.enable
uci set luci_statistics.collectd_mqtt=statistics


if [ -d "/mnt/sda3/" ]; then
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

# 5. 替换源并安装离线包
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi
apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk

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
luci-app-statistics luci-i18n-statistics-zh-cn"

PACKAGES="$PKG_CORE $PKG_DISK $PKG_DEPENDS $PKG_NETWORK $PKG_WIFI_BT $PKG_MONITOR $PKG_LUCI_APPS"

echo ">>> 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已圆满完成！ <<<"
