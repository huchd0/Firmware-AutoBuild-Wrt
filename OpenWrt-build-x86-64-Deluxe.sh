#!/bin/bash
set -e

# ==========================================
# >>> 0. 接收环境变量与初始处理 <<<
# ==========================================
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
    MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

# ==========================================
# >>> 1. 自定义固件参数 (剔除多余镜像格式) <<<
# ==========================================
echo ">>> 正在配置 .config 参数 <<<"
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

# ==========================================
# >>> 2. 准备初始化文件夹 <<<
# ==========================================
echo ">>> 正在创建系统注入目录 <<<"
mkdir -p files/root
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/init.d
mkdir -p files/usr/bin
mkdir -p files/etc/crontabs

# ==========================================
# >>> 3. 下载第三方插件、内核与驱动 <<<
# ==========================================
echo ">>> 正在拉取第三方资源 <<<"

# --- 🎯 抓取 OpenClash ---
OPENCLASH_URL=$(curl -sL https://api.github.com/repos/vernesong/OpenClash/releases | jq -r '.[0].assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)
if [ -n "$OPENCLASH_URL" ]; then
    wget -qO files/root/luci-app-openclash.apk "$OPENCLASH_URL"
fi

# --- 🎯 抓取 Argon 主题 ---
ARGON_URL=$(curl -sL https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | jq -r '.[0].assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)
if [ -n "$ARGON_URL" ]; then
    wget -qO files/root/luci-theme-argon.apk "$ARGON_URL"
fi

# --- 🎯 抓取 NetWiz 网络向导 (主程序 + 中文包) ---
echo "正在获取 Netwiz 最新版本下载链接..."
API_JSON=$(curl -sL https://api.github.com/repos/sdxmhs/luci-app-netwizs/releases)

# 主程序
NETWIZ_URL=$(echo "$API_JSON" | jq -r '.[0].assets[] | select(.name == "apk_luci-app-netwiz.apk") | .browser_download_url' | head -n 1)
# 简体中文包
NETWIZ_ZH_URL=$(echo "$API_JSON" | jq -r '.[0].assets[] | select(.name == "apk_luci-i18n-netwiz-zh-cn.apk") | .browser_download_url' | head -n 1)

if [ -n "$NETWIZ_URL" ]; then
    echo "下载 Netwiz 主程序..."
    wget -qO files/root/luci-app-netwiz.apk "$NETWIZ_URL"
fi

if [ -n "$NETWIZ_ZH_URL" ]; then
    echo "下载 Netwiz 中文包..."
    wget -qO files/root/luci-i18n-netwiz-zh-cn.apk "$NETWIZ_ZH_URL"
fi

echo "正在下载 OpenClash Meta 内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

echo "正在注入 MT7925 官方底层固件..."
mkdir -p files/lib/firmware/mediatek/mt7925
wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin"

# ==========================================
# >>> 4. 编写全自动开机初始化脚本 <<<
# ==========================================
echo ">>> 正在生成初始化与网卡守护脚本 <<<"

cat << 'EOF_WIFI' > files/etc/init.d/wifi-auto-patch
#!/bin/sh /etc/rc.common
START=99

start() {
    (
        WAIT=0
        while [ $WAIT -lt 30 ]; do
            wifi config
            if uci get wireless.radio0 >/dev/null 2>&1; then
                break
            fi
            sleep 2
            WAIT=$((WAIT+1))
        done

        if uci get wireless.radio0 >/dev/null 2>&1; then
            uci set wireless.radio0.band='5g'
            uci set wireless.radio0.channel='149'
            uci set wireless.radio0.htmode='EHT80'
            uci set wireless.radio0.country='AU'
            uci set wireless.radio0.cell_density='0'
            uci set wireless.radio0.txpower='23'
            
            for iface in $(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
                uci set wireless.${iface}.ssid='mywifi7'
                uci set wireless.${iface}.encryption='sae-mixed'
                uci set wireless.${iface}.key='Aa666666'
                uci set wireless.${iface}.ieee80211w='1'
                uci set wireless.${iface}.network='lan'
                uci set wireless.${iface}.mode='ap'
            done
            uci commit wireless
        fi
        
        /etc/init.d/wifi-auto-patch disable
        rm -f /etc/init.d/wifi-auto-patch
    ) &
}
EOF_WIFI
chmod +x files/etc/init.d/wifi-auto-patch

cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 0. 接管首次开机向导 (Netwiz)
uci set luci.main.index='admin/netwiz'
uci commit luci

# 1. 注册 Wi-Fi 智能补全服务
/etc/init.d/wifi-auto-patch enable

# 2. 核心网络设置
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# 3. 强行设置时区与主机名
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# 4. 智能网口分配逻辑
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

# 5. 智能大分区强制挂载保护 (适配 SATA/NVMe/虚拟机)
ROOT_DISK=\$(lsblk -ndo NAME,TYPE | awk '\$2=="disk"{print \$1; exit}')
if [ -n "\$ROOT_DISK" ]; then
    ROOT_DEV="/dev/\$ROOT_DISK"
    if [[ "\$ROOT_DISK" =~ [0-9]$ ]]; then
        PART_DEV="\${ROOT_DEV}p3"
    else
        PART_DEV="\${ROOT_DEV}3"
    fi

    if ! lsblk | grep -q "\${PART_DEV##*/}"; then
        parted -s "\$ROOT_DEV" mkpart primary ext4 0% 100%
        partprobe "\$ROOT_DEV" >/dev/null 2>&1 || true
        sleep 3
        if lsblk | grep -q "\${PART_DEV##*/}"; then
            mkfs.ext4 -F "\$PART_DEV" >/dev/null 2>&1
        fi
    fi

    TARGET_UUID=\$(blkid -s UUID -o value "\$PART_DEV" 2>/dev/null)
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
        
        mkdir -p /mnt/sda3
        mount "\$PART_DEV" /mnt/sda3 2>/dev/null || true
    fi
fi

# 6. 终极性能监控图表修复
if [ -x "/etc/init.d/collectd" ] && [ ! -f "/etc/collectd_inited" ]; then
    [ ! -f "/etc/config/luci_statistics" ] && touch /etc/config/luci_statistics
    uci set luci_statistics.collectd=statistics
    uci set luci_statistics.collectd.BaseDir='/var/run/collectd'
    uci set luci_statistics.collectd.Include='/etc/collectd/conf.d'
    uci set luci_statistics.collectd.PIDFile='/var/run/collectd.pid'
    uci set luci_statistics.collectd.PluginDir='/usr/lib/collectd'
    uci set luci_statistics.collectd.TypesDB='/usr/share/collectd/types.db'
    uci set luci_statistics.collectd.Interval='30'
    uci set luci_statistics.collectd.ReadThreads='2'
    uci set luci_statistics.collectd.enable='1'
    
    uci del luci_statistics.collectd_network.enable 2>/dev/null || true
    uci set luci_statistics.collectd_mqtt=statistics

    if [ -d "/mnt/sda3/" ]; then
        mkdir -p /mnt/sda3/collectd_rrd
        chmod -R 777 /mnt/sda3/collectd_rrd
        uci set luci_statistics.collectd_rrdtool=statistics
        uci set luci_statistics.collectd_rrdtool.enable='1'
        uci set luci_statistics.collectd_rrdtool.DataDir='/mnt/sda3/collectd_rrd'
    fi

    uci set luci_statistics.collectd_thermal=statistics
    uci set luci_statistics.collectd_thermal.enable='1'
    uci set luci_statistics.collectd_sensors=statistics
    uci set luci_statistics.collectd_sensors.enable='1'
    uci set luci_statistics.collectd_interface=statistics
    uci set luci_statistics.collectd_interface.enable='1'
    uci set luci_statistics.collectd_interface.ignoreselected='0'
    uci set luci_statistics.collectd_cpu=statistics
    uci set luci_statistics.collectd_cpu.enable='1'
    
    uci set luci_statistics.collectd_ping=statistics
    uci set luci_statistics.collectd_ping.enable='1'
    uci delete luci_statistics.collectd_ping.Hosts 2>/dev/null
    uci add_list luci_statistics.collectd_ping.Hosts='114.114.114.114'
    uci add_list luci_statistics.collectd_ping.Hosts='8.8.8.8'

    uci commit luci_statistics
    
    /etc/init.d/luci_statistics enable
    /etc/init.d/luci_statistics restart
    /etc/init.d/collectd enable
    /etc/init.d/collectd restart
    touch /etc/collectd_inited
fi

# --- 🎯 7. 强行激活 BBR 网络加速引擎 ---
if ! grep -q "bbr" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi

# 8. 软件源替换与离线 APK 安装
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# >>> 5. 生成全自动静默升级脚本 (双引擎自适应) <<<
# ==========================================
echo ">>> 正在植入全局升级指令 (upg) <<<"
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
                sleep 1
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
                sleep 1
                ;;
        esac
    done
    openclash_after=$(opkg list-installed luci-app-openclash 2>/dev/null)
fi

if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi

echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE

chmod +x files/usr/bin/upg
echo "0 2 */2 * * /usr/bin/upg" > files/etc/crontabs/root
echo "" >> files/etc/crontabs/root
chmod 0600 files/etc/crontabs/root

cat << 'EOF_CRON' > files/etc/uci-defaults/99-cron-enable
#!/bin/sh
/etc/init.d/cron enable
/etc/init.d/cron restart
rm -f /etc/uci-defaults/99-cron-enable
exit 0
EOF_CRON
chmod +x files/etc/uci-defaults/99-cron-enable

# ==========================================
# >>> 6. 固件预装软件列表 (极致分类与注释版) <<<
# ==========================================
echo ">>> 正在配置官方软件列表 <<<"

declare -a PKG_LIST=(
    # 🌐 1. 核心网络控制
    "-dnsmasq"                          # [卸载] 自带的简配版 dnsmasq
    "dnsmasq-full"                      # [安装] 功能完整的 dnsmasq-full

    # 🖥️ 2. Web 管理界面 (LuCI) & 全局中文
    "luci"                              # LuCI 基础框架
    "luci-base"                         # LuCI 底层依赖
    "luci-compat"                       # LuCI 兼容性组件
    "luci-i18n-base-zh-cn"              # LuCI 基础中文包
    "luci-i18n-firewall-zh-cn"          # 防火墙界面中文包
    "luci-i18n-package-manager-zh-cn"   # 软件包管理中文包

    # 💾 3. 磁盘管理与文件系统支持
    "block-mount"                       # 自动挂载支持
    "blkid"                             # UUID 识别工具
    "lsblk"                             # 块设备查看工具
    "parted"                            # 分区管理工具
    "fdisk"                             # 传统磁盘分区工具
    "e2fsprogs"                         # ext4 文件系统工具
    "kmod-usb-storage"                  # USB 存储核心驱动
    "kmod-usb-storage-uas"              # USB 高速传输驱动
    "kmod-fs-ext4"                      # ext4 文件系统驱动
    "kmod-fs-ntfs3"                     # ntfs 高性能挂载驱动
    "kmod-fs-vfat"                      # vfat 文件系统驱动
    "kmod-fs-exfat"                     # exfat 文件系统驱动

    # ⚙️ 4. 核心系统运行依赖
    "coreutils-nohup"                   # 后台运行命令支持
    "coreutils-base64"                  # Base64 编码工具
    "coreutils-sort"                    # 排序工具
    "bash"                              # Bash 解释器
    "jq"                                # JSON 解析工具
    "curl"                              # 网络请求工具
    "ca-bundle"                         # 根证书依赖
    "libcap"                            # 权限控制库
    "libcap-bin"                        # 权限控制工具
    "ruby"                              # Ruby 运行环境
    "ruby-yaml"                         # Ruby YAML 解析支持
    "unzip"                             # 压缩包解压工具

    # 🚀 5. 高级网络与转发控制
    "ip-full"                           # 完整版 iproute2
    "iptables-mod-tproxy"               # Tproxy 透明代理
    "iptables-mod-extra"                # iptables 额外扩展
    "kmod-tun"                          # TUN 虚拟网卡驱动
    "kmod-inet-diag"                    # 网络连接诊断驱动
    "kmod-nft-tproxy"                   # Nftables Tproxy 驱动
    "kmod-igc"                          # Intel 2.5G 网卡驱动
    "kmod-igb"                          # Intel 千兆网卡驱动
    "kmod-r8169"                        # Realtek 网卡驱动
    "iwinfo"                            # 无线硬件信息工具
    "kmod-tcp-bbr"                      # BBR 拥塞控制 (提升代理速度)
    "kmod-nft-offload"                  # 流量卸载引擎 (降低满速下载CPU占用)

    # 📶 6. 无线与蓝牙底层驱动
    "-wpad-basic-mbedtls"               # [卸载] 简配版 WPA 认证
    "-wpad-basic-wolfssl"               # [卸载] 简配版 WPA 认证
    "wpad-openssl"                      # [安装] 完整版 WPA3 认证
    "kmod-mt7925e"                      # MT7925 PCIe 驱动
    "kmod-mt7925-firmware"              # MT7925 固件支持
    "kmod-btusb"                        # 蓝牙 USB 底层驱动
    "bluez-daemon"                      # 蓝牙协议栈守护
    "kmod-input-uinput"                 # 蓝牙输入设备驱动

    # 📊 7. 系统监控与排障工具
    "nano"                              # 命令行文本编辑器
    "htop"                              # 动态资源查看器
    "ethtool"                           # 网卡底层参数调节
    "tcpdump"                           # 命令行抓包工具
    "mtr"                               # 路由追踪工具
    "conntrack"                         # 连接数状态工具
    "iftop"                             # 实时流量监控
    "screen"                            # 多窗口终端
    "collectd-mod-thermal"              # 性能图表: 温度监控
    "collectd-mod-sensors"              # 性能图表: 传感器数据
    "collectd-mod-cpu"                  # 性能图表: CPU 负载
    "collectd-mod-ping"                 # 性能图表: 网络延迟
    "collectd-mod-interface"            # 性能图表: 接口流量
    "collectd-mod-rrdtool"              # 性能图表: 数据库落盘
    "collectd-mod-iwinfo"               # 性能图表: 无线状态

    # 🧩 8. 扩展应用插件
    "luci-app-ttyd"                     # 网页终端命令行
    "luci-i18n-ttyd-zh-cn"              # 网页终端中文包
    "luci-app-ksmbd"                    # 内核级 SMB 共享
    "luci-i18n-ksmbd-zh-cn"             # SMB 共享中文包
    "luci-app-nlbwmon"                  # 网络带宽精准监控
    "luci-i18n-nlbwmon-zh-cn"           # 带宽监控中文包
    "luci-app-statistics"               # 性能统计全功能图表
    "luci-i18n-statistics-zh-cn"        # 性能图表中文包
    "luci-app-upnp"                     # UPnP 自动端口转发界面
    "luci-i18n-upnp-zh-cn"              # UPnP 界面中文包
    "miniupnpd-nftables"                # UPnP 底层服务 (基于 nftables)
)

# ==========================================
# >>> 7. 开始编译打包 <<<
# ==========================================
echo ">>> 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="${PKG_LIST[*]}" FILES="files"

echo ">>> 8. 提取并清理生成的固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi.img.gz output-firmware/ 2>/dev/null || true

echo ">>> 🎉 全部构建任务已圆满完成！ <<<"
