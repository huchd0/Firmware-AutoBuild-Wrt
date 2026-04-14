#!/bin/bash
set -e

# ==========================================
# 接收 Github Actions (Docker 容器) 传来的环境变量
# ==========================================
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
# 接收从 YAML 工作流中动态传入的管理 IP
MANAGEMENT_IP=${MANAGEMENT_IP:-"192.168.100.1"}
# 如果 YAML 里没有传拨号账号密码，默认留空
PPPOE_ACCOUNT=${PPPOE_ACCOUNT:-""}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-""}

echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建定制固件 (无Docker轻量版)..."
echo "RootFS 大小: $ROOTFS_SIZE MB | 路由器动态管理 IP: $MANAGEMENT_IP"

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
# 将所有下载任务放入后台并行执行
(
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
) &
( wget -qO files/etc/openclash/GeoIP.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" ) &
( wget -qO files/etc/openclash/GeoSite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" ) &

FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
( wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "$FW_URL/BT_RAM_CODE_MT7925_1_1_hdr.bin" ) &

# 挂起主线程，等待所有文件瞬间就绪
wait
echo "✅ 所有组件及底层驱动并发拉取完毕！"

echo ">>> 4. 生成开机首启初始化脚本 (精准网络与IP配置) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 设置时区和主机名
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# A. 基础 LAN 桥接与 IP 设置 (动态获取外部传入的IP)
uci set network.lan.ipaddr="$MANAGEMENT_IP"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

清除官方默认生成的物理网口绑定(防止系统默认把 eth0 绑在 LAN 导致冲突)
while uci -q delete network.@device[0]; do :; done

# 安全地创建属于我们的 br-lan 桥接设备
uci set network.br_lan='device'
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'

# B. 智能网口分配 (解决 eth0 冲突)
INTERFACES=\$(ls /sys/class/net | grep -E '^eth[0-9]+' | sort)
PORT_COUNT=\$(echo "\$INTERFACES" | wc -w)

if [ "\$PORT_COUNT" -eq 1 ]; then
    # 单网口：只有 eth0，作为 LAN
    uci add_list network.br_lan.ports='eth0'
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
else
    # 多网口：eth0 作为 WAN/WAN6，其余全部桥接进 LAN
    for iface in \$INTERFACES; do
        if [ "\$iface" = "eth0" ]; then
            # 配置 WAN (IPv4)
            uci set network.wan='interface'
            uci set network.wan.device='eth0'
            
            if [ -n "$PPPOE_ACCOUNT" ] && [ -n "$PPPOE_PASSWORD" ]; then
                uci set network.wan.proto='pppoe'
                uci set network.wan.username="$PPPOE_ACCOUNT"
                uci set network.wan.password="$PPPOE_PASSWORD"
                uci set network.wan.ipv6='auto'
            else
                uci set network.wan.proto='dhcp'
            fi
            
            # 配置 WAN6 (IPv6)
            uci set network.wan6='interface'
            uci set network.wan6.proto='dhcpv6'
            uci set network.wan6.device='eth0'
        else
            # 将多余的网口（eth1, eth2...）加入 LAN 桥接
            uci add_list network.br_lan.ports="\$iface" 
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

# D. 激活 Argon 主题
if uci get luci.themes.Argon >/dev/null 2>&1; then
    uci set luci.main.mediaurlbase='/luci-static/argon'
    uci commit luci
fi

# E. Wi-Fi 7 后台安全配置逻辑 (防抓空/防死配置机制)
(
    # 轮询等待底层网卡驱动和固件加载，最多等待 60 秒 (30次 x 2秒)
    for i in \$(seq 1 30); do
        # 尝试生成默认无线配置
        wifi config >/dev/null 2>&1
        # 检查 UCI 中是否成功生成了包含底层硬件绑定(path/mac)的 radio0
        if uci get wireless.radio0 >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    # 只有确信 radio0 的底层配置已经成功生成后，才覆盖我们的自定义参数
    if uci get wireless.radio0 >/dev/null 2>&1; then
        uci set wireless.radio0.band='5g'
        uci set wireless.radio0.channel='149'
        uci set wireless.radio0.country='CN'
        uci set wireless.radio0.cell_density='0'
        uci set wireless.radio0.disabled='0'  # 0代表开启

        # 如果接口尚未生成，补齐接口配置
        if ! uci get wireless.default_radio0 >/dev/null 2>&1; then
            uci set wireless.default_radio0=wifi-iface
            uci set wireless.default_radio0.device='radio0'
            uci set wireless.default_radio0.network='lan'
            uci set wireless.default_radio0.mode='ap'
        fi

        uci set wireless.default_radio0.encryption='sae-mixed'
        uci set wireless.default_radio0.ssid='mywifi7'
        uci set wireless.default_radio0.key='Aa666666'
        uci set wireless.default_radio0.ocv='0'
        uci set wireless.default_radio0.disabled='0'  # 0代表开启

        uci commit wireless
        # 配置完后，无缝重启无线服务使配置立即生效
        wifi reload
    fi
) &

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

echo ">>> 5. 组装极简与指定软件包列表 <<<"
PACKAGES=""
# 系统基础与语言包
PACKAGES="$PACKAGES luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn"
# 文件系统、挂载与磁盘管理
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn block-mount fdisk parted lsblk e2fsprogs kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-exfat kmod-usb-storage-uas"
# 命令行工具 (含指定的 script-utils)
PACKAGES="$PACKAGES bash curl jq unzip nano htop tcpdump mtr iwinfo script-utils"
# 主题外观
PACKAGES="$PACKAGES luci-theme-argon"
# 核心网络插件
PACKAGES="$PACKAGES luci-app-openclash luci-i18n-homeproxy-zh-cn luci-i18n-ddns-go-zh-cn"
# 文件共享与传输管理
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn luci-app-ksmbd luci-i18n-ksmbd-zh-cn openssh-sftp-server"
# 硬件驱动 (MT7925)
PACKAGES="$PACKAGES kmod-mt7925e wpad-openssl kmod-btusb bluez-daemon kmod-input-uinput kmod-mt7925-firmware"

# 强制 IPv4 优先防卡死，其余全交由官方环境直连
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 6. [CPU多核镇压] 开始 Make Image 打包 <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-Deluxe" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo ">>> 7. 剔除多余格式，提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete

echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建任务顺利完成！"
