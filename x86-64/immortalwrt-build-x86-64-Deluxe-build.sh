#!/bin/bash
set -e

# 接收環境變量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

echo ">>> 1. 固件參數配置 <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
    echo "CONFIG_GRUB_IMAGES=n"
} >> .config

echo ">>> 2. 準備組件與驅動 <<<"
mkdir -p files/etc/uci-defaults files/etc/openclash/core files/lib/firmware/mediatek/mt7925

# 並發下載核心驅動 (直連美國源，極速)
( wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta && chmod +x files/etc/openclash/core/clash_meta ) &
( wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin" ) &
wait

echo ">>> 3. 編寫初始化腳本 (J4125 專屬) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 核心網路
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 自動掛載與 Docker 數據遷移
if ! lsblk | grep -q sda3; then
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 2
    mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
fi

UUID=\$(blkid -s UUID -o value /dev/sda3)
if [ -n "\$UUID" ]; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
    mkdir -p /mnt/sda3 && mount /dev/sda3 /mnt/sda3
    # 自動將 Docker 遷移至大分區
    uci set dockerd.globals.data_root='/mnt/sda3/docker'
    uci commit dockerd
fi

# 主題激活
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

echo ">>> 4. 軟體列表 (官方源直連) <<<"
# 僅保留核心包，讓系統自動計算依賴，避免觸發 Cloudflare 限速
PACKAGES="luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn \
luci-theme-argon luci-app-openclash \
dockerd docker-compose luci-app-dockerman \
fdisk block-mount e2fsprogs kmod-fs-ext4 \
kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl \
bash curl jq htop"

# 【提速神技】強制 IPv4 優先，繞過 GitHub Actions 的 DNS 延遲
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 5. 開始打包 <<<"
# 使用 -j$(nproc) 拉滿多核性能
make image -j\$(nproc) PROFILE="generic" PACKAGES="\$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-J4125"

echo ">>> 6. 清理與提取 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete
