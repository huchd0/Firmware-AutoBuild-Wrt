#!/bin/bash
set -e

# ==========================================
# 接收 Github Actions (Docker 容器) 传来的环境变量
# ==========================================
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"yes"}
PPPOE_ACCOUNT=${PPPOE_ACCOUNT:-""}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-""}

# 缓存目录设定 (映射自宿主机)
DL_CACHE=${DL_CACHE_DIR:-"/home/build/immortalwrt/dl_cache"}
mkdir -p "$DL_CACHE"

echo ">>> 1. 自定义固件底层参数 (专属 J4125 互刷防掉盘) <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
    echo "CONFIG_VMDK_IMAGES=n"
    echo "CONFIG_VDI_IMAGES=n"
    echo "CONFIG_VHDX_IMAGES=n"
    echo "CONFIG_QCOW2_IMAGES=n"
    echo "CONFIG_ISO_IMAGES=n"
    echo "CONFIG_GRUB_IMAGES=n"
} >> .config

echo ">>> 2. 准备初始化文件夹结构 <<<"
mkdir -p files/root files/etc/uci-defaults files/etc/init.d files/usr/bin files/etc/openclash/core files/lib/firmware/mediatek/mt7925

echo ">>> 3. [极限并发] 缓存提取与多线程切片下载组件 <<<"
# 智能下载：有缓存秒拷，无缓存动用 aria2 开启 4 线程多路并发防限速
smart_dl() {
    local URL=$1
    local DEST=$2
    local CACHE_FILE="$DL_CACHE/$(basename "$DEST")"
    
    if [ -s "$CACHE_FILE" ]; then
        echo "⚡ [缓存命中] 极速复用: $(basename "$DEST")"
        cp "$CACHE_FILE" "$DEST"
    else
        echo "⬇️ [Aria2 多线程下载] 未命中缓存: $(basename "$DEST")"
        aria2c --console-log-level=error --summary-interval=0 -x 4 -s 4 -d "$(dirname "$DEST")" -o "$(basename "$DEST")" "$URL" || true
        [ -s "$DEST" ] && cp "$DEST" "$CACHE_FILE"
    fi
}

GH_HEADER=""
[ -n "$GITHUB_TOKEN" ] && GH_HEADER="-H \"Authorization: Bearer $GITHUB_TOKEN\""

echo "正在并发获取 GitHub 最新 Releases 下载链接..."
OPENCLASH_URL=$(eval curl -s $GH_HEADER https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
ARGON_URL=$(eval curl -s $GH_HEADER https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)

echo "开启并发下载池..."
( [ -n "$OPENCLASH_URL" ] && smart_dl "$OPENCLASH_URL" files/root/luci-app-openclash.apk ) &
( [ -n "$ARGON_URL" ] && smart_dl "$ARGON_URL" files/root/luci-theme-argon.apk ) &
( smart_dl "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" files/etc/openclash/core/meta.tar.gz ) &

# 【优化】换用 kernel.org 纯净源避免 GitLab 抽风
( smart_dl "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin" files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin ) &
( smart_dl "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin" files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin ) &
( smart_dl "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin" files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin ) &

wait
echo "✅ 所有组件及底层驱动准备完毕！"

if [ -f files/etc/openclash/core/meta.tar.gz ]; then
    tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    rm -f files/etc/openclash/core/meta.tar.gz
fi


echo ">>> 4. 编写全自动静默升级脚本 <<<"
cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
LOGFILE="/root/upg.log"
[ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt 1048576 ] && echo "日志过大，已清空重建" > "$LOGFILE"
echo "===== Auto Upgrade Start: $(date) =====" >> "$LOGFILE"

if command -v apk >/dev/null 2>&1; then
    openclash_before=$(apk info -v luci-app-openclash 2>/dev/null)
    apk update >> "$LOGFILE" 2>&1
    apk upgrade >> "$LOGFILE" 2>&1
    openclash_after=$(apk info -v luci-app-openclash 2>/dev/null)
else
    echo "仅支持 apk 包管理器。" >> "$LOGFILE"
    exit 1
fi

if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi
echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE
chmod +x files/usr/bin/upg


echo ">>> 5. 生成开机首启初始化脚本 (含自动拨号与 Docker 网络注入) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# A. 管理 IP 配置
if [ -f "/etc/config/custom_router_ip.txt" ]; then
    MY_IP=\$(cat /etc/config/custom_router_ip.txt | tr -d '\n' | tr -d '\r')
    if [[ ! "\$MY_IP" == *"/"* ]]; then MY_IP="\${MY_IP}/24"; fi
    uci set network.lan.ipaddr="\$MY_IP"
    uci delete network.@device[0].ports 2>/dev/null
    uci set network.lan.device='br-lan'
    uci delete network.lan.type 2>/dev/null
    rm -f /etc/config/custom_router_ip.txt
fi

uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# B. 智能网口与 WAN 口配置
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
            uci set network.wan.device='eth0'
            
            if [ -n "$PPPOE_ACCOUNT" ] && [ -n "$PPPOE_PASSWORD" ]; then
                uci set network.wan.proto='pppoe'
                uci set network.wan.username="$PPPOE_ACCOUNT"
                uci set network.wan.password="$PPPOE_PASSWORD"
                uci set network.wan.ipv6='auto'
            else
                uci set network.wan.proto='dhcp'
                uci set network.wan6='interface'
                uci set network.wan6.proto='dhcpv6'
                uci set network.wan6.device='eth0'
            fi
        else
            uci add_list network.@device[0].ports="\$iface" 
        fi
    done
fi
uci commit network

# C. 强制挂载大分区
if ! lsblk | grep -q sda3; then
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1; fi
fi

TARGET_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$TARGET_UUID" ]; then
    echo -e "config 'global'\n  option  anon_swap   '0'\n  option  anon_mount  '0'\n  option  auto_swap   '1'\n  option  auto_mount  '1'\n  option  delay_root  '5'\n  option  check_fs    '0'" > /etc/config/fstab
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$TARGET_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# D. Docker 自动化网络与防火墙配置
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    if [ -d "/mnt/sda3/" ]; then
        uci set dockerd.globals.data_root='/mnt/sda3/docker'
        uci commit dockerd
    fi
    
    if ! uci get firewall.docker >/dev/null 2>&1; then
        uci add firewall zone
        uci set firewall.@zone[-1].name='docker'
        uci set firewall.@zone[-1].network='docker'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='ACCEPT'
        
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='docker'
        uci set firewall.@forwarding[-1].dest='wan'
        
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='docker'
        uci commit firewall
    fi
fi

echo "0 2 */2 * * /usr/bin/upg" >> /etc/crontabs/root
/etc/init.d/cron restart 2>/dev/null || true

if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

(
    WAIT_NET=0
    while [ \$WAIT_NET -lt 30 ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            apk update
            apk add luci-app-ttyd luci-i18n-ttyd-zh-cn
            apk add -q --allow-untrusted /root/*.apk
            rm -f /root/*.apk
            
            if uci get luci.themes.Argon >/dev/null 2>&1; then
                uci set luci.main.mediaurlbase='/luci-static/argon'
                uci commit luci
            fi
            break
        fi
        sleep 5; WAIT_NET=\$((WAIT_NET+1))
    done
) &

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup


echo ">>> 6. 配置官方纯净软件列表 <<<"

RAW_PACKAGES="
    -dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn
    block-mount blkid lsblk parted fdisk e2fsprogs kmod-usb-storage kmod-usb-storage-uas kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat kmod-fs-exfat
    coreutils-nohup coreutils-base64 coreutils-sort bash jq curl ca-bundle libcap libcap-bin ruby ruby-yaml unzip
    ip-full iptables-mod-tproxy iptables-mod-extra kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-igc kmod-igb kmod-r8169 iwinfo
    
    # 【核心减负】去掉了巨无霸 bluez-daemon 及其引发的 dbus 等 400+ 桌面级依赖，只保留核心硬件驱动
    -wpad-basic-mbedtls -wpad-basic-wolfssl wpad-openssl kmod-mt7925e kmod-mt7925-firmware kmod-btusb
    
    nano htop ethtool tcpdump mtr conntrack iftop screen collectd-mod-thermal collectd-mod-sensors collectd-mod-cpu collectd-mod-ping collectd-mod-interface collectd-mod-rrdtool collectd-mod-iwinfo
    luci-app-ksmbd luci-i18n-ksmbd-zh-cn luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn luci-app-statistics luci-i18n-statistics-zh-cn
"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    RAW_PACKAGES="$RAW_PACKAGES dockerd docker-compose kmod-veth kmod-macvlan kmod-dummy luci-app-dockerman luci-i18n-dockerman-zh-cn"
    echo "🐳 已激活 Docker 组件及相关网络内核支持"
fi

PACKAGES=$(echo "$RAW_PACKAGES" | sed 's/#.*//g' | tr -s ' \n' ' ')

echo ">>> 7. [多核极速] 开始 Make Image 打包 <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-Deluxe" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo ">>> 8. 剔除多余格式，确保仅输出 combined-efi <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete

echo ">>> 全部任务以极限速度构建完毕！ <<<"
