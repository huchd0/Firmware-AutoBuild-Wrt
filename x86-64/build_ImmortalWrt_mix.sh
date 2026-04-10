#!/bin/bash
set -e

# 1. 基础环境参数
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}
[ [[ ! "$MANAGEMENT_IP" == *"/"* ]] ] && MANAGEMENT_IP="${MANAGEMENT_IP}/24"

echo ">>> 1. 自定义固件参数 <<<"
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config
# 仅生成 UEFI Squashfs
for fmt in EXT4FS TARGZ VMDK VDI VHDX QCOW2 ISO GRUB; do echo "CONFIG_TARGET_ROOTFS_${fmt}=n" >> .config 2>/dev/null || echo "CONFIG_${fmt}_IMAGES=n" >> .config; done

echo ">>> 2. 准备初始化文件夹 <<<"
mkdir -p files/root files/etc/uci-defaults

echo ">>> 3. 下载插件 (ImmortalWrt IPK) <<<"
# OpenClash
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

# Argon Theme
AG_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$AG_URL" ] && wget -qO files/root/luci-theme-argon.ipk "$AG_URL"

# Meta Core 注入
mkdir -p files/etc/openclash/core
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 4. 编写全自动初始化脚本 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- A. 网络与系统设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxmix'
uci commit system

# --- B. 智能网口分配 ---
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

# --- C. 核心：动态抓取 sda3 UUID 并配置挂载 ---
# 路由器启动时现场识别硬件
sleep 3
REAL_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$REAL_UUID" ]; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- D. 镜像源与插件自动安装 ---
# 换源至中科大
if [ -f "/etc/opkg/distfeeds.conf" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/opkg/distfeeds.conf
fi

opkg update
opkg install /root/*.ipk
rm -rf /root/*.ipk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 软件包配置 <<<"
PACKAGES="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd \
block-mount blkid lsblk parted fdisk e2fsprogs coreutils-nohup bash curl ca-bundle \
ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun unzip iwinfo"

echo ">>> 6. 开始打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已完成！ <<<"
