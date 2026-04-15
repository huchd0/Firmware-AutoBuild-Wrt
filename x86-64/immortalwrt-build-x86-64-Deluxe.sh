#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-yes}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
    MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

echo "=== 1. 自定义固件参数 (互刷保护) ==="
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

echo "=== 2. 准备初始化文件夹 ==="
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/init.d
mkdir -p files/usr/bin
mkdir -p files/etc/crontabs

echo "=== 3. 下载必要核心与驱动固件 ==="

echo "正在下载 OpenClash Meta 兼容版内核..."
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

echo "=== 4. 编写全自动开机初始化脚本 ==="

cat << 'EOF_WIFI' > files/etc/init.d/wifi-auto-patch
#!/bin/sh /etc/rc.common
START=99

start() {
    # 将探测和修改逻辑放进后台 ( ) & 执行，绝对不阻塞路由器开机速度
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
            
            # 【核心修复】强制重启无线服务，让 mywifi7 立刻生效！
            sleep 2
            wifi reload
        fi
        
        # 任务完成，自我销毁
        rm -f /etc/init.d/wifi-auto-patch
    ) &
}
EOF_WIFI
chmod +x files/etc/init.d/wifi-auto-patch


cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# 开启 Wi-Fi 智能补全服务
/etc/init.d/wifi-auto-patch enable

# --- A1. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# --- A2. 强行设置时区与主机名 ---
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
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

# --- C. 智能大分区强制挂载保护 ---
if ! lsblk | grep -q sda3; then
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

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
    
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# --- D. 性能监控图表修复 ---
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

# --- D2. Docker 自动化网络互通配置 ---
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    [ ! -f "/etc/config/dockerd" ] && touch /etc/config/dockerd
    uci set dockerd.globals=globals
    uci set dockerd.globals.data_root='/mnt/sda3/docker'
    uci commit dockerd
fi

if uci get luci.themes.Argon >/dev/null 2>&1; then
    uci set luci.main.mediaurlbase='/luci-static/argon'
    uci commit luci
fi

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup


# ==========================================
# --- E. 终端神器 ttyd 联网自动补装 (双引擎自适应版) ---
# ==========================================
cat << 'EOF_TTYD' > files/etc/init.d/install-ttyd
#!/bin/sh /etc/rc.common
START=99
start() {
    WAIT_NET=0
    while [ $WAIT_NET -lt 60 ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            # 智能嗅探包管理器
            if command -v apk >/dev/null 2>&1; then
                apk update
                apk add luci-app-ttyd luci-i18n-ttyd-zh-cn
            elif command -v opkg >/dev/null 2>&1; then
                opkg update
                opkg install luci-app-ttyd luci-i18n-ttyd-zh-cn
            fi
            rm -f /etc/init.d/install-ttyd
            break
        fi
        sleep 5
        WAIT_NET=$((WAIT_NET+1))
    done
}
EOF_TTYD
chmod +x files/etc/init.d/install-ttyd
mkdir -p files/etc/rc.d
ln -s ../init.d/install-ttyd files/etc/rc.d/S99install-ttyd

# ==========================================
# --- F. 全自动静默升级与定时任务 (双引擎自适应版) ---
# ==========================================
echo "正在生成自动升级脚本与定时任务..."

cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
LOGFILE="/root/upg.log"

if [ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt 1048576 ]; then
    echo "日志过大，已清空重建" > "$LOGFILE"
fi

echo "===== Auto Upgrade Start: $(date) =====" >> "$LOGFILE"

# 1. 嗅探当前环境
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

# 2. 根据引擎执行相应的安全升级逻辑
if [ "$PKG_ENGINE" = "apk" ]; then
    apk update >> "$LOGFILE" 2>&1
    # 获取可升级列表，提取包名并过滤掉敏感的内核与底层包
    apk list -u 2>/dev/null | awk '{print $1}' | sed -E 's/-[0-9]+.*//' | while read -r pkg; do
        if [ -z "$pkg" ]; then continue; fi
        case "$pkg" in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|procd|uhttpd)
                # 核心底层包，跳过
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
                # 核心底层包，跳过
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                opkg upgrade "$pkg" >> "$LOGFILE" 2>&1
                ;;
        esac
    done
    openclash_after=$(opkg list-installed luci-app-openclash 2>/dev/null)
fi

# 3. OpenClash 守护重启逻辑
if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级 ($openclash_before -> $openclash_after)，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi

echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE

chmod +x files/usr/bin/upg
mkdir -p files/etc/crontabs

# 写入定时任务 (注意结尾加换行，有些 crond 实现很挑剔)
echo "0 2 */2 * * /usr/bin/upg" > files/etc/crontabs/root
echo "" >> files/etc/crontabs/root

# 🎯 赋予 crontab 正确的安全权限 (600)，否则计划任务会失效
chmod 0600 files/etc/crontabs/root


echo "=== 5. 配置 ImmortalWrt 专属软件列表 ==="

# --- 1. 核心系统与基础 UI ---
PKG_CORE=(
    "-dnsmasq"                         # 排除基础版 dnsmasq
    "-dnsmasq-default"                 # 排除默认 dnsmasq 配置
    "dnsmasq-full"                     # 替换为全功能版（科学上网、透明代理必需支持）
    "luci"                             # 路由器 Web 管理后台主程序
    "luci-base"                        # Luci 基础依赖
    "luci-compat"                      # Luci 旧版兼容包（很多第三方插件依赖它）
    "luci-i18n-base-zh-cn"             # 基础系统界面的中文语言包
    "luci-i18n-firewall-zh-cn"         # 防火墙界面的中文语言包
    "luci-i18n-package-manager-zh-cn"  # 软件包管理（系统-软件包）的中文语言包
)

# --- 2. 磁盘、文件系统与 USB 扩展 ---
PKG_DISK=(
    "block-mount"                      # 挂载点管理工具（自动挂载大分区必备）
    "blkid"                            # 查看磁盘 UUID 和属性
    "lsblk"                            # 树状显示磁盘列表
    "parted"                           # 高级磁盘分区工具
    "fdisk"                            # 基础磁盘分区工具
    "e2fsprogs"                        # ext4 文件系统格式化与修复工具 (mkfs.ext4)
    "kmod-usb-storage"                 # USB 存储设备基础驱动
    "kmod-usb-storage-uas"             # USB 3.0 UASP 高速协议加速驱动（防掉盘、提速）
    "kmod-fs-ext4"                     # ext4 文件系统内核支持
    "kmod-fs-ntfs3"                    # Windows NTFS 文件系统高效挂载驱动
    "kmod-fs-vfat"                     # FAT32 文件系统驱动 (老旧 U 盘)
    "kmod-fs-exfat"                    # exFAT 文件系统驱动 (新版 U 盘/移动硬盘)
    "luci-i18n-diskman-zh-cn"          # 磁盘管理插件界面的中文包
    "luci-i18n-filemanager-zh-cn"      # 网页版文件浏览器（方便直接在后台传文件）
)

# --- 3. 脚本、系统工具与依赖库 ---
PKG_DEPENDS=(
    "coreutils-nohup"                  # 允许命令在后台静默运行
    "bash"                             # 行业标准的 Shell 终端环境
    "jq"                               # JSON 数据解析工具（各种脚本必备）
    "curl"                             # 强大的网络请求下载工具
    "ca-bundle"                        # 根证书包（修复 https 访问报错）
    "libcap"                           # 权限控制核心库
    "libcap-bin"                       # 权限控制命令工具
    "ruby"                             # Ruby 运行环境
    "ruby-yaml"                        # Ruby 的 YAML 解析库 (OpenClash 运行依赖)
    "unzip"                            # zip 压缩包解压工具
)

# --- 4. 网络加速、防火墙与网卡驱动 ---
PKG_NETWORK=(
    "ip-full"                          # 全功能的高级路由策略配置工具
    "iptables-mod-tproxy"              # 透明代理模块（旁路由/科学上网核心）
    "iptables-mod-extra"               # 防火墙额外扩展模块
    "kmod-tun"                         # 虚拟网卡隧道模块 (OpenClash/VPN 必备)
    "kmod-inet-diag"                   # 网络连接诊断分析模块
    "kmod-nft-tproxy"                  # 基于 Nftables 的透明代理模块
    "kmod-igc"                         # Intel i225/i226 2.5G 网卡驱动 (J4125 软路由标配)
    "kmod-igb"                         # Intel 千兆网卡驱动
    "kmod-r8169"                       # Realtek 瑞昱千兆/2.5G 网卡基础驱动
    "iwinfo"                           # 查看无线网卡详细信息的工具
    "kmod-tcp-bbr"                     # 开启 Google BBR 拥塞控制算法（有效降低网络延迟）
)

# --- 5. Wi-Fi 7 与 蓝牙 核心组件 ---
PKG_WIFI_BT=(
    "-wpad"                            # 排除默认的无线加密包
    "-wpad-basic"                      # 排除基础版
    "-wpad-basic-mbedtls"              # 排除低配版
    "-wpad-basic-wolfssl"              # 排除低配版
    "-wpad-mbedtls"                    # 排除低配版
    "-wpad-wolfssl"                    # 排除低配版
    "wpad-openssl"                     # 强制使用性能最强、最全能的 OpenSSL 加密（Wi-Fi 核心）
    "kmod-mt7925e"                     # 联发科 MT7925 Wi-Fi 7 PCI-E 网卡驱动
    "kmod-mt7925-firmware"             # MT7925 底层固件
    "kmod-btusb"                       # 蓝牙 USB 驱动
    "bluez-daemon"                     # 蓝牙守护进程
    "kmod-input-uinput"                # 模拟用户输入模块（部分蓝牙外设依赖）
)

# --- 6. 性能监控与故障排查工具 ---
PKG_MONITOR=(
    "nano"                             # 简单易用的命令行文本编辑器
    "htop"                             # 高级彩色系统资源监控器 (比 top 更好用)
    "ethtool"                          # 物理网卡配置工具 (用于开启/关闭网卡特定功能)
    "tcpdump"                          # 网络抓包神器
    "mtr"                              # 路由追踪与连通性测试工具
    "conntrack"                        # 连接数跟踪查看工具
    "iftop"                            # 实时网络流量监控
    "screen"                           # 终端多任务会话保持工具
    "collectd-mod-thermal"             # 收集 CPU 温度数据
    "collectd-mod-sensors"             # 收集主板传感器数据
    "collectd-mod-cpu"                 # 收集 CPU 负载数据
    "collectd-mod-ping"                # 收集网络延迟数据
    "collectd-mod-interface"           # 收集网卡流量数据
    "collectd-mod-rrdtool"             # 生成监控数据数据库
    "collectd-mod-iwinfo"              # 收集无线网络质量数据
)

# --- 7. 物理硬件与底层工具 ---
PKG_HW_TOOLS=(
    "pciutils"                         # 列出和查看 PCI/PCI-E 硬件设备 (lspci)
    "iperf3"                           # 局域网极限测速工具
    "intel-microcode"                  # Intel CPU 核心微代码补丁 (修复 J4125 漏洞，提升稳定性)
)

# --- 8. 核心应用与界面插件 ---
PKG_LUCI_APPS=(
    "luci-app-openclash"               # OpenClash 科学上网客户端
    "luci-app-homeproxy"               # HomeProxy 科学上网客户端（备用/轻量选择）
    "luci-i18n-homeproxy-zh-cn"        # HomeProxy 中文包
    "luci-theme-argon"                 # 最受欢迎的 Argon 漂亮主题
    "luci-app-ksmbd"                   # 苹果/Windows 网络共享 (性能比旧版 Samba4 更高)
    "luci-i18n-ksmbd-zh-cn"            # Ksmbd 中文包
    "luci-app-statistics"              # 酷炫的路由器性能/流量监控图表
    "luci-i18n-statistics-zh-cn"       # 监控图表中文包
    "luci-app-autoreboot"              # 计划任务：定时重启路由器
    "luci-i18n-autoreboot-zh-cn"       # 定时重启中文包
)

# --- 9. Docker 虚拟化环境 ---
PKG_DOCKER=()
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PKG_DOCKER=(
        "dockerd"                      # Docker 核心守护引擎
        "docker-compose"               # 支持运行 yaml 容器编排文件
        "luci-app-dockerman"           # Web 网页版 Docker 管理界面
        "luci-i18n-dockerman-zh-cn"    # Docker 管理界面中文包
    )
fi

# 合并所有模块
ALL_PKGS=(
    "${PKG_CORE[@]}"
    "${PKG_DISK[@]}"
    "${PKG_DEPENDS[@]}"
    "${PKG_NETWORK[@]}"
    "${PKG_WIFI_BT[@]}"
    "${PKG_MONITOR[@]}"
    "${PKG_HW_TOOLS[@]}"
    "${PKG_LUCI_APPS[@]}"
    "${PKG_DOCKER[@]}"
)

PACKAGES="${ALL_PKGS[*]}"

echo ">>> 6. 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo ">>> 7. 精准重命名与纯净提取 <<<"
cd bin/targets/x86/64/

# 1. 明确寻找那个唯一能刷机的 combined 固件
TARGET_FILE=$(ls *squashfs-combined-efi.img.gz 2>/dev/null | head -n 1)

if [ -n "$TARGET_FILE" ]; then
    # 2. 强行给它戴上 -Deluxe 的帽子
    NEW_NAME="${TARGET_FILE%.img.gz}-Deluxe.img.gz"
    mv "$TARGET_FILE" "$NEW_NAME"
    echo "✅ 成功截获并重命名核心固件: $NEW_NAME"
fi

# 3. 暴力清场：把所有没被改成 Deluxe 的垃圾镜像（比如 rootfs 或 ext4 格式）全部删掉！
find . -type f -name "*.img.gz" ! -name "*-Deluxe.img.gz" -delete
# 顺手清理除了 Deluxe固件 和 sha256校验文件 之外的所有杂项
find . -type f -not -name "*-Deluxe.img.gz" -not -name "*sha256sums" -delete

cd -
