#!/bin/bash
set -e

# ==========================================
# 接收 Github Actions (Docker 容器) 传来的环境变量
# ==========================================
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"yes"}
PPPOE_ACCOUNT=${PPPOE_ACCOUNT:-""}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-""}

echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建 Deluxe 固件..."
echo "RootFS 大小: $ROOTFS_SIZE MB | 集成 Docker: $INCLUDE_DOCKER"

echo ">>> 1. 自定义固件底层参数 <<<"
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

echo ">>> 3. [极限并发] 核心组件多线程秒下 <<<"
# 将所有下载任务放入后台并行执行，极限压榨北美机房带宽，耗时从十几秒压缩到 1-2 秒
(
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
) &
( wget -qO files/etc/openclash/GeoIP.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" ) &
( wget -qO files/etc/openclash/GeoSite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" ) &

FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
( wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "$FW_URL/BT_RAM_CODE_MT7925_1_1_hdr.bin" ) &
( wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin "$FW_URL/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin" ) &
( wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "$FW_URL/WIFI_RAM_CODE_MT7925_1_1.bin" ) &

# 挂起主线程，等待所有文件瞬间就绪
wait
echo "✅ 所有组件及底层驱动并发拉取完毕！"

echo ">>> 4. 生成开机首启初始化脚本 (含自动拨号与 Docker 网络注入) <<<"
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
    echo -e "w\n" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw\n" | fdisk /dev/sda >/dev/null 2>&1
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

# 激活 Argon 主题
if uci get luci.themes.Argon >/dev/null 2>&1; then
    uci set luci.main.mediaurlbase='/luci-static/argon'
    uci commit luci
fi

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 组装极简官方软件列表 <<<"
PACKAGES=""
PACKAGES="$PACKAGES luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES block-mount fdisk parted lsblk e2fsprogs kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-exfat kmod-usb-storage-uas"
PACKAGES="$PACKAGES bash curl jq unzip nano htop tcpdump mtr iwinfo"
PACKAGES="$PACKAGES kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl"
PACKAGES="$PACKAGES luci-i18n-ksmbd-zh-cn luci-i18n-nlbwmon-zh-cn luci-i18n-statistics-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash luci-theme-argon luci-app-argon-config"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES dockerd docker-compose kmod-veth kmod-macvlan kmod-dummy luci-app-dockerman luci-i18n-dockerman-zh-cn"
fi

# 强制 IPv4 优先防卡死，其余全交由官方环境直连
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 6. [CPU多核镇压] 开始 Make Image 打包 <<<"
# 加入 -j$(nproc) 强行拉满 Github 机器的所有 CPU 核心，极速压缩系统镜像！
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-Deluxe" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo ">>> 7. 剔除多余格式，提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete

echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建任务极限完成！"
