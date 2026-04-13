#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量 (支持本地独立运行时的默认值)
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

echo ">>> 4. 编写全自动开机初始化脚本 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# --- A. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# --- 系统基础设置 (时区与主机名) ---
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxmix'
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

# --- C. 智能大分区挂载保护 (动态抓取 UUID) ---
# 兼容 NVMe 和常规 SATA/USB 存储，寻找第三个分区
TARGET_DEV=""
if [ -b "/dev/nvme0n1p3" ]; then
    TARGET_DEV="/dev/nvme0n1p3"
elif [ -b "/dev/sda3" ]; then
    TARGET_DEV="/dev/sda3"
fi

if [ -n "\$TARGET_DEV" ]; then
    # 动态获取该分区的真实 UUID
    TARGET_UUID=\$(blkid -s UUID -o value "\$TARGET_DEV")
    
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
fi

# --- D. 软件源与插件安装 ---
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 配置官方软件列表 (纯净极简版) <<<"
# 追加了 e2fsprogs 以支持 mkfs.ext4 和 resize2fs (为 Docker 分区做准备)
PACKAGES="-dnsmasq dnsmasq-full \
luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn \
luci-i18n-package-manager-zh-cn \
luci-app-ttyd luci-i18n-ttyd-zh-cn \
luci-app-ksmbd luci-i18n-ksmbd-zh-cn \
block-mount blkid lsblk parted fdisk e2fsprogs \
kmod-usb-storage kmod-usb-storage-uas kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat \
coreutils-nohup bash curl ca-bundle ip-full iptables-mod-tproxy iptables-mod-extra \
libcap libcap-bin ruby ruby-yaml kmod-tun kmod-inet-diag unzip kmod-nft-tproxy kmod-igc iwinfo"

echo ">>> 6. 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已圆满完成！ <<<"
