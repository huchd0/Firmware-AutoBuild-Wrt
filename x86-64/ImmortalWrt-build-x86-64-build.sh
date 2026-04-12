#!/bin/bash
set -e

echo "========== 开始 ImmortalWrt 定制构建 =========="

# 1. 接收外部环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}
[ [[ ! "$MANAGEMENT_IP" == *"/"* ]] ] && MANAGEMENT_IP="${MANAGEMENT_IP}/24"

# 2. 修改底层配置文件 (.config)
echo ">>> 配置系统参数与分区大小..."
sed -i '/CONFIG_TARGET_KERNEL_PARTSIZE/d' .config
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
sed -i '/CONFIG_TARGET_ROOTFS_PARTSIZE/d' .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

# 暴力清理多余的虚拟机镜像配置，避免报错，强制保留 squashfs 和 efi
for var in CONFIG_TARGET_ROOTFS_EXT4FS CONFIG_TARGET_ROOTFS_TARGZ CONFIG_QCOW2_IMAGES CONFIG_VDI_IMAGES CONFIG_VMDK_IMAGES CONFIG_VHDX_IMAGES CONFIG_ISO_IMAGES; do
    sed -i "/${var}/d" .config
    echo "# ${var} is not set" >> .config
done
sed -i '/CONFIG_TARGET_ROOTFS_SQUASHFS/d' .config
echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y" >> .config
sed -i '/CONFIG_EFI_IMAGES/d' .config
echo "CONFIG_EFI_IMAGES=y" >> .config

# 3. 准备初始化文件夹
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 4. 下载第三方插件包
echo ">>> 下载 OpenClash 与 Argon 主题..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

AG_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$AG_URL" ] && wget -qO files/root/luci-theme-argon.ipk "$AG_URL"

echo ">>> 预置 OpenClash Meta 兼容内核..."
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

# 5. 注入全自动初始化脚本 (开机执行，用完即焚)
echo ">>> 编写 99-custom-setup 开机启动脚本..."
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- 基础与网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# --- 智能网口分配 ---
INTERFACES=\$(ls /sys/class/net | grep -E '^eth[0-9]+' | sort)
if [ "\$(echo \$INTERFACES | wc -w)" -gt 1 ]; then
    uci set network.wan='interface'
    uci set network.wan.proto='dhcp'
    uci set network.wan.device='eth0'
    for iface in \$INTERFACES; do
        [ "\$iface" != "eth0" ] && uci add_list network.@device[0].ports="\$iface"
    done
else
    uci add_list network.@device[0].ports='eth0'
fi
uci commit network

# --- 自动挂载 sda3 (剩余空间) ---
sleep 3
REAL_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$REAL_UUID" ]; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 换源与离线插件安装 ---
if [ -f "/etc/opkg/distfeeds.conf" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/opkg/distfeeds.conf
fi
opkg update
opkg install /root/*.ipk
rm -rf /root/*.ipk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 6. 配置软件包清单
echo ">>> 定义软件包..."
PACKAGES="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd \
block-mount blkid lsblk parted fdisk e2fsprogs coreutils-nohup bash curl ca-bundle \
ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun unzip iwinfo"

# 7. 开始打包
echo ">>> 正在执行 Make Image 编译..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo "========== 编译流程执行完毕 =========="
# 注意：不需要手动 cp 提取文件了，Docker 的 Volume 映射会自动将其同步到宿主机的 bin/ 目录下！
