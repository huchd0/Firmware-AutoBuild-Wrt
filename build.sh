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

echo ">>> 3. 下载第三方 APK 插件与 OpenClash 核心 <<<"
OPENCLASH_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
if [ -n "$OPENCLASH_URL" ]; then
    echo "正在下载 OpenClash APK..."
    wget -qO files/root/luci-app-openclash.apk "$OPENCLASH_URL"
fi

ARGON_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
if [ -n "$ARGON_URL" ]; then
    echo "正在下载 Argon 主题 APK..."
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

# 1. 创建精确的层级目录
mkdir -p files/lib/firmware/mediatek/mt7925

# 2. 下载蓝牙固件 (通常位于 mediatek/ 根目录)
wget -qO files/lib/firmware/mediatek/BT_RAM_CODE_MT7925_1_1_hdr.bin \
"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/BT_RAM_CODE_MT7925_1_1_hdr.bin"

# 3. 下载 Wi-Fi 固件 (根据你提供的准确路径，放入 mt7925/ 子目录)
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin \
"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin"

wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin \
"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin"

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
    echo "Detecting unallocated space, creating /dev/sda3..."
    # 修复可能存在的 GPT 表尾部错误，并保存
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    # 自动新建第三分区并使用全部剩余空间
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    
    # 【改动在这里】使用 partprobe 刷新分区表，如果失败则尝试 block info 触发
    partprobe /dev/sda >/dev/null 2>&1 || block info >/dev/null 2>&1 || true
    sleep 3
    
    # 格式化
    if lsblk | grep -q sda3; then
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

# 动态获取 sda3 的 UUID 并配置挂载
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
fi

# --- D. 软件源与插件安装 (纯离线秒装模式) ---
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

# 直接执行本地安装，因为依赖已经在打包时放入 PACKAGES 中了
apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 配置官方软件列表 <<<"

# 1. 核心网络与网页后台 (基础底座)
PKG_CORE="-dnsmasq dnsmasq-full \
luci luci-base luci-compat \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn"

# 2. 磁盘管理与文件系统 (大分区与存储支持)
PKG_DISK="block-mount blkid lsblk parted fdisk e2fsprogs \
kmod-usb-storage kmod-usb-storage-uas \
kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat kmod-fs-exfat"

# 3. 核心依赖与系统工具 (OpenClash 及日常脚本运行基础)
PKG_DEPENDS="coreutils-nohup coreutils-base64 coreutils-sort bash jq curl ca-bundle \
libcap libcap-bin ruby ruby-yaml unzip"

# 4. 网络底层驱动与防火墙扩展 (代理与有线网络支持)
PKG_NETWORK="ip-full iptables-mod-tproxy iptables-mod-extra kmod-tun kmod-inet-diag \
kmod-nft-tproxy kmod-igc iwinfo"

# 5. 无线与蓝牙扩展 (MT7925 专属增强)
# 强制移除默认简版 wpad，替换为 openssl 完整版以支持更高级的加密(如 WPA3)
PKG_WIFI_BT="-wpad-basic-mbedtls -wpad-basic-wolfssl wpad-openssl \
kmod-mt7925e kmod-mt7925-firmware \
kmod-btusb bluez-daemon kmod-input-uinput"

# 6. 网络诊断与性能监控 (排障全家桶)
PKG_MONITOR="nano htop ethtool tcpdump mtr conntrack iftop screen"

# 7. LuCI 应用插件 (网页端实用功能)
PKG_LUCI_APPS="luci-app-ttyd luci-i18n-ttyd-zh-cn \
luci-app-ksmbd luci-i18n-ksmbd-zh-cn \
luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn"

# 8. 合并所有模块并赋值给 PACKAGES
PACKAGES="$PKG_CORE $PKG_DISK $PKG_DEPENDS $PKG_NETWORK $PKG_WIFI_BT $PKG_MONITOR $PKG_LUCI_APPS"

echo ">>> 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已圆满完成！ <<<"
