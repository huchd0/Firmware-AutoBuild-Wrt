#!/bin/bash
set -e

# 接收环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

echo ">>> 1. 固件骨架参数 <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
} >> .config

echo ">>> 2. 从官方仓库预下载核心组件 (直连秒下) <<<"
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# A. 下载 OpenClash 官方 Release 的最新 APK (确保开机就有界面)
echo "正在获取 OpenClash 官方 APK..."
OC_APK_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
wget -qO files/root/luci-app-openclash.apk "$OC_APK_URL"

# B. 下载 OpenClash Meta 兼容版内核 (确保开机就能跑)
echo "正在获取 OpenClash Meta 内核..."
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 3. 编写悟空式开机静默脚本 <<<"
cat << EOF > files/etc/uci-defaults/99-init-setup
#!/bin/sh

# 1. 系统基础设置
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit

# 2. 安装预置的 OpenClash APK
apk add --allow-untrusted /root/luci-app-openclash.apk
rm -f /root/luci-app-openclash.apk

# 3. 磁盘分区与挂载 (J4125 专属)
if ! lsblk | grep -q sda3; then
    (echo n; echo 3; echo ""; echo ""; echo w) | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 2
    mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
fi

# 4. 后台补全任务 (联网后执行)
(
    while ! ping -c 1 -n -W 1 8.8.8.8 >/dev/null 2>&1; do
        sleep 5
    done

    # 换源提速并补全剩余包
    sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/apk/repositories.d/*.list
    apk update
    apk add luci-i18n-homeproxy-zh-cn luci-i18n-samba4-zh-cn \
            luci-app-argon-config dockerd docker-compose luci-app-dockerman \
            kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl
    
    # 迁移 Docker 目录
    mkdir -p /mnt/sda3/docker
    uci set dockerd.globals.data_root='/mnt/sda3/docker'
    uci commit dockerd
    /etc/init.d/dockerd restart
) &

rm -f /etc/uci-defaults/99-init-setup
exit 0
EOF

echo ">>> 4. 软件列表 (极致骨架) <<<"
# 仅保留基础包，强制排除所有多余驱动
PACKAGES="base-files libc libgcc apk-openssl block-mount fdisk e2fsprogs kmod-fs-ext4 \
bash curl jq htop luci-theme-argon luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-ttyd-zh-cn \
kmod-igc kmod-r8125 kmod-r8169 \
-kmod-amazon-ena -kmod-bnx2 -kmod-i40e -kmod-ixgbe -kmod-tg3 -kmod-vmxnet3"

echo ">>> 5. 开始快速构建 <<<"
# 通过 http 协议和 DNS 绑定进一步压榨官方源速度
if [ -f "repositories.conf" ]; then
    sed -i 's/https:\/\//http:\/\//g' repositories.conf
    echo "104.21.75.148 downloads.immortalwrt.org" >> /etc/hosts
fi

make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="Wukong-Style"

echo ">>> 6. 提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -delete
