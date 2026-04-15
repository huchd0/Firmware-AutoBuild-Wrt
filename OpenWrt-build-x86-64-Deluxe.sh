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

# 提前下载并注入 OpenClash Meta 兼容版内核
echo "正在下载 OpenClash Meta 兼容版内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

# --- 注入 MT7925 官方蓝牙与无线固件 (GitLab 锁定版本) ---
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
# --- 🎯 核心黑科技：后台自动抓取真实 PCI 路径，注入专属 Wi-Fi 参数 ---
# ===================================================================
cat << 'EOF_WIFI' > files/etc/init.d/wifi-auto-patch
#!/bin/sh /etc/rc.common
START=99

start() {
    (
        WAIT=0
        # 躲在后台等，最多等一分钟，直到系统自动探测出物理网卡
        while [ $WAIT -lt 30 ]; do
            # 强制系统探测硬件并生成配置
            wifi config
            if uci get wireless.radio0 >/dev/null 2>&1; then
                break
            fi
            sleep 2
            WAIT=$((WAIT+1))
        done

        # 一旦发现系统抓到了真实的 PCI 路径 (radio0 存在)
        if uci get wireless.radio0 >/dev/null 2>&1; then
            # 保留系统抓到的 option path，只覆盖你的参数
            uci set wireless.radio0.band='5g'
            uci set wireless.radio0.channel='149'
            uci set wireless.radio0.htmode='EHT80'
            uci set wireless.radio0.country='AU'
            uci set wireless.radio0.cell_density='0'
            uci set wireless.radio0.txpower='23'
            
            # 找到无线接口，注入你的名字和密码
            for iface in $(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
                uci set wireless.${iface}.ssid='mywifi7'
                uci set wireless.${iface}.encryption='sae-mixed'
                uci set wireless.${iface}.key='Aa666666'
                # 强力纠错：WPA3必须开启PMF
                uci set wireless.${iface}.ieee80211w='1'
                uci set wireless.${iface}.network='lan'
                uci set wireless.${iface}.mode='ap'
            done
            
            # 提交保存，但不去启动它，让你可以在 LuCI 里手动点击开启
            uci commit wireless
        fi
        
        # 任务完成，自我销毁
        /etc/init.d/wifi-auto-patch disable
        rm -f /etc/init.d/wifi-auto-patch
    ) &
}
EOF_WIFI
chmod +x files/etc/init.d/wifi-auto-patch


cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 注册我们的 Wi-Fi 智能补全服务
/etc/init.d/wifi-auto-patch enable

# --- A1. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# --- A2. 强行设置时区为中国 (Asia/Shanghai) ---
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
    
    # 立刻创建目录并挂载，确保下一步图表能写进硬盘
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# --- D. 终极性能监控图表修复 (采用你的 MQTT 幽灵配置神操作) ---
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
    
    # 🎯 利用假配置骗开图表假死管道
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
    
    # 重启引擎，使配置立即生效
    /etc/init.d/luci_statistics enable
    /etc/init.d/luci_statistics restart
    /etc/init.d/collectd enable
    /etc/init.d/collectd restart
    
    touch /etc/collectd_inited
fi

# --- E. 软件源与插件安装 ---
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# --- F. 全自动静默升级与定时任务 (双引擎自适应版) ---
# ==========================================
echo "正在生成自动升级脚本与定时任务..."

# 🌟 创建目录
mkdir -p files/usr/bin

cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
LOGFILE="/root/upg.log"

if [ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt 1048576 ]; then
    echo "日志过大，已清空重建" > "$LOGFILE"
fi

echo "===== Auto Upgrade Start: $(date) =====" >> "$LOGFILE"

# 1. 嗅探当前环境
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

# 2. 根据引擎执行相应的安全升级逻辑
if [ "$PKG_ENGINE" = "apk" ]; then
    apk update >> "$LOGFILE" 2>&1
    # 获取可升级列表，提取包名并过滤掉敏感的内核与底层包
    apk list -u 2>/dev/null | awk '{print $1}' | sed -E 's/-[0-9]+.*//' | while read -r pkg; do
        if [ -z "$pkg" ]; then continue; fi
        case "$pkg" in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|procd|uhttpd)
                # 核心底层包，跳过
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                apk add -u "$pkg" >> "$LOGFILE" 2>&1
                ;;
        esac
    done
    openclash_after=$(apk info -v luci-app-openclash 2>/dev/null)
    
elif [ "$PKG_ENGINE" = "opkg" ]; then
    opkg update >> "$LOGFILE" 2>&1
    for pkg in $(opkg list-upgradable | awk '{print $1}'); do
        case "$pkg" in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|opkg|procd|uhttpd)
                # 核心底层包，跳过
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                opkg upgrade "$pkg" >> "$LOGFILE" 2>&1
                ;;
        esac
    done
    openclash_after=$(opkg list-installed luci-app-openclash 2>/dev/null)
fi

# 3. OpenClash 守护重启逻辑
if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级 ($openclash_before -> $openclash_after)，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi

echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE

chmod +x files/usr/bin/upg
mkdir -p files/etc/crontabs

# 写入定时任务 (注意结尾加换行，有些 crond 实现很挑剔)
echo "0 2 */2 * * /usr/bin/upg" > files/etc/crontabs/root
echo "" >> files/etc/crontabs/root

# 🎯 赋予 crontab 正确的安全权限 (600)，否则计划任务会失效
chmod 0600 files/etc/crontabs/root

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

# 纯净版，不包含导致报错的 mqtt 插件包
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
