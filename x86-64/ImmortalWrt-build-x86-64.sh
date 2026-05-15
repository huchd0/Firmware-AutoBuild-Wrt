#!/bin/bash
set -e

# ==========================================
# 接收 Github Actions (Docker 容器) 传来的环境变量
# ==========================================
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-"192.168.100.1"}
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
# 1. 下载 OpenClash Meta 兼容版内核
(
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
) &
( wget -qO files/etc/openclash/GeoIP.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" ) &
( wget -qO files/etc/openclash/GeoSite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" ) &

# 2. 下载 MT7925 Wi-Fi 底层核心固件
FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
( wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "$FW_URL/BT_RAM_CODE_MT7925_1_1_hdr.bin" ) &
( wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin "$FW_URL/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin" ) &
( wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "$FW_URL/WIFI_RAM_CODE_MT7925_1_1.bin" ) &

# 3. 下载 NetWiz 网络向导 (智能探测 apk/ipk 并后台并发拉取)
(
    echo "正在探测固件包管理器并获取对应格式的 NetWiz ..."
    mkdir -p files/root/netwiz_pkgs
    
    # 智能判定当前 ImageBuilder 使用的包管理器格式
    if command -v apk >/dev/null 2>&1; then
        PKG_EXT="apk"
    else
        PKG_EXT="ipk"
    fi
    
    # 精准拉取对应后缀名 (.apk 或 .ipk) 的三个文件
    curl -sL https://api.github.com/repos/huchd0/luci-app-netwiz/releases/latest | \
    jq -r ".assets[] | select(.name | endswith(\".\${PKG_EXT}\")) | .browser_download_url" | \
    while read -r url; do
        wget -qP files/root/netwiz_pkgs/ "$url"
    done
) &

# 挂起主线程，等待所有后台下载任务瞬间就绪
wait
echo "✅ 所有组件、底层驱动及第三方插件并发拉取完毕！"

echo ">>> 4. 生成开机首启初始化脚本 (精准网络与IP配置) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 设置时区和主机名
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# A. 基础 LAN 桥接与 IP 设置
uci set network.lan.ipaddr="$MANAGEMENT_IP"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# 清除官方默认生成的物理网口绑定(防止系统默认把 eth0 绑在 LAN 导致冲突)
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

# E. Wi-Fi 7 后台安全配置逻辑 (多频自适应防冲突版)
(
    count=0
    while [ \$count -lt 30 ]; do
        wifi config >/dev/null 2>&1
        if uci get wireless.radio0 >/dev/null 2>&1; then
            break
        fi
        sleep 2
        count=\$((count + 1))
    done

    if uci get wireless.radio0 >/dev/null 2>&1; then
        for radio in \$(uci show wireless | grep -E '^wireless.radio[0-9]+=' | cut -d'.' -f2 | cut -d'=' -f1); do
            uci set wireless.\${radio}.country='CN'
            uci set wireless.\${radio}.cell_density='0'
            uci set wireless.\${radio}.disabled='0'

            iface="default_\${radio}"
            if ! uci get wireless.\${iface} >/dev/null 2>&1; then
                uci set wireless.\${iface}=wifi-iface
                uci set wireless.\${iface}.device="\${radio}"
                uci set wireless.\${iface}.network='lan'
                uci set wireless.\${iface}.mode='ap'
            fi

            uci set wireless.\${iface}.encryption='sae-mixed'
            uci set wireless.\${iface}.ssid='mywifi7'
            uci set wireless.\${iface}.key='Aa666666'
            uci set wireless.\${iface}.ocv='0'
            uci set wireless.\${iface}.disabled='0'
        done
        
        uci set wireless.radio0.band='5g'
        uci set wireless.radio0.channel='149'
        
        if uci get wireless.radio1 >/dev/null 2>&1; then
            uci set wireless.radio1.band='2g'
            uci set wireless.radio1.channel='1'
        fi

        uci commit wireless
        wifi reload
    fi
) &

# F. 自动安装本地 NetWiz 插件
if [ -d "/root/netwiz_pkgs" ]; then
    # 根据系统包管理器，精准匹配对应的文件后缀进行安装
    if command -v apk >/dev/null 2>&1; then
        apk add --allow-untrusted /root/netwiz_pkgs/*.apk >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        opkg install /root/netwiz_pkgs/*.ipk --force-depends >/dev/null 2>&1 || true
    fi
    # 阅后即焚，清理安装包释放空间
    rm -rf /root/netwiz_pkgs
fi

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# G. 全自动静默升级与定时任务 (双引擎自适应版)
echo "正在生成自动升级脚本与定时任务..."

mkdir -p files/usr/bin

cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
LOGFILE="/root/upg.log"

if [ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt 1048576 ]; then
    echo "日志过大，已清空重建" > "$LOGFILE"
fi

echo "===== Auto Upgrade Start: $(date) =====" >> "$LOGFILE"

if command -v apk >/dev/null 2>&1; then
    PKG_ENGINE="apk"
    openclash_before=$(apk info -v luci-app-openclash 2>/dev/null)
elif command -v opkg >/dev/null 2>&1; then
    PKG_ENGINE="opkg"
    openclash_before=$(opkg list-installed luci-app-openclash 2>/dev/null)
else
    echo "未找到支持的包管理器！" >> "$LOGFILE"
    exit 1
fi

echo "使用 $PKG_ENGINE 引擎执行升级..." >> "$LOGFILE"

if [ "$PKG_ENGINE" = "apk" ]; then
    apk update >> "$LOGFILE" 2>&1
    apk list -u 2>/dev/null | awk '{print $1}' | sed -E 's/-[0-9]+.*//' | while read -r pkg; do
        if [ -z "$pkg" ]; then continue; fi
        case "$pkg" in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|procd|uhttpd)
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                apk add -u "$pkg" >> "$LOGFILE" 2>&1
                ;;
        esac
    done
    openclash_after=$(apk info -v luci-app-openclash 2>/dev/null)
    
elif [ "$PKG_ENGINE" = "opkg" ]; then
    opkg update >> "$LOGFILE" 2>&1
    for pkg in $(opkg list-upgradable | awk '{print $1}'); do
        case "$pkg" in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|opkg|procd|uhttpd)
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                opkg upgrade "$pkg" >> "$LOGFILE" 2>&1
                ;;
        esac
    done
    openclash_after=$(opkg list-installed luci-app-openclash 2>/dev/null)
fi

if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级 ($openclash_before -> $openclash_after)，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi

echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE

chmod +x files/usr/bin/upg
mkdir -p files/etc/crontabs

echo "0 2 */2 * * /usr/bin/upg" > files/etc/crontabs/root
echo "" >> files/etc/crontabs/root
chmod 0600 files/etc/crontabs/root

echo ">>> 5. 组装极简与指定软件包列表 <<<"
declare -a PKG_LIST=(
    "-dnsmasq"                        # 明确剔除基础版 dnsmasq
    "dnsmasq-full"                    # 强制安装全功能版 (OpenClash 必需)
    "-kmod-nft-fullcone"              # 排除新版本中已废弃的模块，防止依赖报错
    
    # --- OpenClash 必需底层依赖 ---
    "libcap"
    "libcap-bin"
    "ruby"
    "ruby-yaml"
    
    # --- 🔐 核心 SSL 与证书支持 (确保 opkg 可用 HTTPS 源) ---
    "ca-bundle"                       # 根证书集合包
    "ca-certificates"                 # 基础 CA 证书
    "libustream-openssl"              # uclient-fetch 的 OpenSSL 支持库 (opkg 必需)
    
    # --- 系统基础与界面 ---
    "luci"
    "luci-base"
    "luci-compat"
    "luci-i18n-base-zh-cn"
    "luci-i18n-firewall-zh-cn"
    "luci-i18n-package-manager-zh-cn"
    "luci-i18n-ttyd-zh-cn"
    "luci-theme-argon"
    
    # --- 磁盘与文件系统 ---
    "luci-i18n-diskman-zh-cn"
    "block-mount"
    "fdisk"
    "parted"
    "lsblk"
    "e2fsprogs"
    "kmod-fs-ext4"
    "kmod-fs-ntfs3"
    "kmod-fs-exfat"
    "kmod-usb-storage-uas"
    
    # --- 命令行与网络诊断工具 (全能版) ---
    "bash"
    "curl"
    "jq"
    "unzip"
    "nano"
    "htop"
    "tcpdump"
    "mtr"
    "iwinfo"
    "script-utils"
    "iperf3"                          # 局域网/Wi-Fi极限测速
    "ethtool"                         # 网口物理状态查询
    "pciutils"                        # lspci (排查 PCIe)
    "usbutils"                        # lsusb (排查 USB/蓝牙)
    "bind-dig"                        # DNS 诊断工具
    "lsof"                            # 端口占用查询
    
    # --- 核心网络插件 ---
    "luci-app-openclash"
    "luci-i18n-homeproxy-zh-cn"
    "luci-i18n-ddns-go-zh-cn"
    
    # --- 文件共享与传输 ---
    "luci-i18n-filemanager-zh-cn"
    "luci-app-samba4"                 # 兼容性极强的 Samba4
    "luci-i18n-samba4-zh-cn"
    "wsdd2"                           # Windows 10/11 网络邻居自动发现神器
    "openssh-sftp-server"
    
    # --- MT7925 硬件驱动 ---
    "kmod-mt7925e"
    "wpad-openssl"
    "kmod-btusb"
    "bluez-daemon"
    "kmod-input-uinput"
    "kmod-mt7925-firmware"
)

# 转换数组为字符串传递给打包引擎
PACKAGES="${PKG_LIST[*]}"

# 强制 IPv4 优先防卡死
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 6. [CPU多核镇压] 开始 Make Image 打包 <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-Deluxe" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo ">>> 7. 剔除多余格式，提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete

echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建任务顺利完成！"
