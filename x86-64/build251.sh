#!/bin/bash
set -e

# 1. 环境参数
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

[ [[ ! "$MANAGEMENT_IP" == *"/"* ]] ] && MANAGEMENT_IP="${MANAGEMENT_IP}/24"

echo ">>> 1. 修改分区大小与固件格式 <<<"
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config
# 极致精简：仅保留 UEFI combined 格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
for fmt in VMDK VDI VHDX QCOW2 ISO GRUB; do echo "CONFIG_${fmt}_IMAGES=n" >> .config; done

echo ">>> 2. 准备系统预设文件 <<<"
mkdir -p files/root files/etc/uci-defaults

echo ">>> 3. 下载插件 (ImmortalWrt 适配 .ipk) <<<"
# OpenClash
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

# Argon Theme
AG_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$AG_URL" ] && wget -qO files/root/luci-theme-argon.ipk "$AG_URL"

# Meta 内核注入
mkdir -p files/etc/openclash/core
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 4. 编写全自动初始化逻辑 (含 UUID 自动抓取) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- 网络与基础设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxmix'
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

# --- 核心：自动抓取 UUID 并挂载 sda3 ---
# 稍微延迟确保硬件就绪
sleep 2
REAL_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$REAL_UUID" ]; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# 智能适配 apk 或 opkg 换源
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
    sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/apk/repositories.d/*.list
elif [ -f "/etc/opkg/distfeeds.conf" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/opkg/distfeeds.conf
fi

# 智能安装插件
if command -v apk >/dev/null; then
    apk add -q --allow-untrusted /root/*.apk 2>/dev/null
    apk add -q --allow-untrusted /root/*.ipk 2>/dev/null
else
    opkg update
    opkg install /root/*.ipk
fi

echo ">>> 5. 定义软件包 (适配 ImmortalWrt) <<<"
PACKAGES="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd \
block-mount blkid lsblk parted fdisk e2fsprogs coreutils-nohup bash curl ca-bundle \
ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun unzip iwinfo"

echo ">>> 6. 打包固件 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 归档 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/#!/bin/bash
set -e

# 1. 环境参数
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

[ [[ ! "$MANAGEMENT_IP" == *"/"* ]] ] && MANAGEMENT_IP="${MANAGEMENT_IP}/24"

echo ">>> 1. 修改分区大小与固件格式 <<<"
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config
# 极致精简：仅保留 UEFI combined 格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
for fmt in VMDK VDI VHDX QCOW2 ISO GRUB; do echo "CONFIG_${fmt}_IMAGES=n" >> .config; done

echo ">>> 2. 准备系统预设文件 <<<"
mkdir -p files/root files/etc/uci-defaults

echo ">>> 3. 下载插件 (ImmortalWrt 适配 .ipk) <<<"
# OpenClash
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

# Argon Theme
AG_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$AG_URL" ] && wget -qO files/root/luci-theme-argon.ipk "$AG_URL"

# Meta 内核注入
mkdir -p files/etc/openclash/core
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 4. 编写全自动初始化逻辑 (含 UUID 自动抓取) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- 网络与基础设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxmix'
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

# --- 核心：自动抓取 UUID 并挂载 sda3 ---
# 稍微延迟确保硬件就绪
sleep 2
REAL_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$REAL_UUID" ]; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 换源与离线安装 ---
sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/opkg/distfeeds.conf
opkg update
opkg install /root/*.ipk
rm -rf /root/*.ipk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 定义软件包 (适配 ImmortalWrt) <<<"
PACKAGES="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd \
block-mount blkid lsblk parted fdisk e2fsprogs coreutils-nohup bash curl ca-bundle \
ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun unzip iwinfo"

echo ">>> 6. 打包固件 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 归档 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/
