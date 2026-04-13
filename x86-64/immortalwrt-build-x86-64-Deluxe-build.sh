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
# --- F. 优雅内置：全自动静默升级与定时任务 (双引擎自适应版) ---
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
    apk upgrade >> "$LOGFILE" 2>&1
    openclash_after=$(apk info -v luci-app-openclash 2>/dev/null)
    
elif [ "$PKG_ENGINE" = "opkg" ]; then
    opkg update >> "$LOGFILE" 2>&1
    for pkg in $(opkg list-upgradable | awk '{print $1}'); do
        case $pkg in
            base-files|busybox|dnsmasq*|dropbear|firewall*|fstools|kernel|kmod-*|libc|luci|mtd|opkg|procd|uhttpd)
                ;;
            *)
                echo "升级: $pkg" >> "$LOGFILE"
                opkg upgrade $pkg >> "$LOGFILE" 2>&1
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
echo "0 2 */2 * * /usr/bin/upg" >> files/etc/crontabs/root

# ==========================================
# 模块化定义软件包 (全能豪华 + Wi-Fi 7 支持版)
# ==========================================

echo "=== 5. 配置 ImmortalWrt 专属软件列表 ==="

# 【1. 核心系统与后台界面】
PKG_CORE=(
    "-dnsmasq"                          # 卸载默认的简易版 dnsmasq
    "-dnsmasq-default"                  # 卸载默认的 dnsmasq 配置文件
    "dnsmasq-full"                      # 安装完整版 dnsmasq (支持 IPv6、ipset、nftables，科学上网防污染必备)
    "luci"                              # OpenWrt 网页后台基础框架
    "luci-base"                         # 网页后台核心依赖库
    "luci-compat"                       # 兼容层库 (确保老版本的插件也能正常运行)
    "luci-i18n-base-zh-cn"              # 网页后台基础界面【中文语言包】
    "luci-i18n-firewall-zh-cn"          # 防火墙设置界面【中文语言包】
    "luci-i18n-package-manager-zh-cn"   # 新版 apk 软件包管理器 (Software菜单)【中文语言包】
)

# 【2. 磁盘挂载与文件系统支持】
PKG_DISK=(
    "block-mount"                       # 系统核心组件：负责开机自动挂载磁盘和 Swap 分区
    "blkid"                             # 命令行工具：查看磁盘的 UUID 和文件系统类型
    "lsblk"                             # 命令行工具：以树状图列出所有块设备(磁盘)
    "parted"                            # 现代全能分区工具 (原生支持 GPT 和超大硬盘，Diskman 依赖它)
    # "fdisk"                           # (已按极致优化原则剔除，有 parted 足矣)
    "e2fsprogs"                         # Ext2/3/4 文件系统格式化和维护工具集
    "kmod-usb-storage"                  # USB 存储设备基础驱动
    "kmod-usb-storage-uas"              # USB 存储设备 UAS 协议加速驱动 (极大提升外接硬盘读写速度)
    "kmod-fs-ext4"                      # 原生 Ext4 文件系统挂载支持 (Linux标准格式)
    "kmod-fs-ntfs3"                     # 现代高性能 NTFS 挂载支持 (插 Windows 硬盘必备)
    "kmod-fs-vfat"                      # FAT32 文件系统挂载支持 (兼容老U盘)
    "kmod-fs-exfat"                     # exFAT 文件系统挂载支持 (兼容大容量U盘)
    "luci-i18n-diskman-zh-cn"           # 网页版磁盘管理 UI (可视化分区、格式化)
    "luci-i18n-filemanager-zh-cn"       # 网页版文件浏览器 (方便在线上传/下载文件)
)

# 【3. 科学插件底层依赖与基础工具】
PKG_DEPENDS=(
    "coreutils-nohup"                   # 允许程序在后台挂机运行的工具
    "bash"                              # 强大的命令行终端环境
    "jq"                                # 命令行 JSON 解析工具 (部分脚本处理 API 时会用到)
    "curl"                              # 命令行网络请求工具 (下载测速、获取订阅必备)
    "ca-bundle"                         # 根证书凭据库 (防止 HTTPS 请求报 SSL 错误)
    "libcap"                            # Linux 进程权限控制底层库
    "libcap-bin"                        # 进程权限管理命令行工具 (OpenClash 需要它获取内核权限)
    "ruby"                              # Ruby 运行环境 (OpenClash 核心组件依赖)
    "ruby-yaml"                         # Ruby YAML 解析库 (用于解析机场订阅配置文件)
    "unzip"                             # ZIP 解压缩工具
)

# 【4. 网络驱动与流量调度增强】
PKG_NETWORK=(
    "ip-full"                           # 完整版 iproute2 网络配置工具 (策略路由必备)
    "iptables-mod-tproxy"               # iptables 透明代理模块 (接管局域网流量必备)
    "iptables-mod-extra"                # iptables 扩展规则模块
    "kmod-tun"                          # 虚拟隧道网卡驱动 (Tun 模式/真全局模式必备)
    "kmod-inet-diag"                    # 网络连接诊断模块 (科学插件连接面板监控所需)
    "kmod-nft-tproxy"                   # 新版 nftables 透明代理模块 (适配最新内核防火墙)
    "kmod-igc"                          # Intel i225/i226 2.5G 网卡专属驱动
    "kmod-igb"                          # Intel 千兆网卡驱动
    "kmod-r8169"                        # Realtek 系列网卡通用驱动
    "iwinfo"                            # 无线网络信息查询工具
    "kmod-tcp-bbr"                      # BBR 拥塞控制算法 (极大提升网络吞吐量，告别拥堵)
)

# 【5. Wi-Fi 7 与 蓝牙 硬件支持】
PKG_WIFI_BT=(
    "-wpad"                             # (卸载各种老旧或阉割版的无线安全守护进程)
    "-wpad-basic"
    "-wpad-basic-mbedtls"
    "-wpad-basic-wolfssl"
    "-wpad-mbedtls"
    "-wpad-wolfssl"
    "wpad-openssl"                      # 安装完整版无线安全守护进程 (支持 WPA3 等现代加密协议)
    "kmod-mt7925e"                      # MT7925 (Wi-Fi 7) PCI-E 无线网卡驱动
    "kmod-mt7925-firmware"              # MT7925 无线网卡底层闭源运行固件
    "kmod-btusb"                        # 通用 USB 蓝牙驱动
    "bluez-daemon"                      # 官方蓝牙协议栈守护进程
    "kmod-input-uinput"                 # 用户空间输入驱动 (用于支持蓝牙键盘/鼠标等输入设备)
)

# 【6. 专业级网络与系统监控神器】
PKG_MONITOR=(
    "nano"                              # 简易友好的命令行文本编辑器 (比 vi 好用)
    "htop"                              # 交互式系统进程监控工具 (彩色的高级任务管理器)
    "ethtool"                           # 网卡物理状态查询与调试工具 (可查网卡是千兆还是2.5G)
    "tcpdump"                           # 强大的命令行网络抓包工具
    "mtr"                               # 结合 ping 和 traceroute 的网络节点诊断神器
    "conntrack"                         # 实时连接追踪状态查询工具
    "iftop"                             # 实时查看各个 IP 网络流量的监控工具
    "screen"                            # 终端多路复用器 (跑长任务时防止 SSH 断线导致任务终止)
    "collectd-mod-thermal"              # 硬件温度采集模块 (配合 luci-app-statistics 绘图)
    "collectd-mod-sensors"              # 传感器数据采集模块
    "collectd-mod-cpu"                  # CPU 负载采集模块
    "collectd-mod-ping"                 # 网络延迟采集模块
    "collectd-mod-interface"            # 网卡流量采集模块
    "collectd-mod-rrdtool"              # 监控数据存储引擎模块
    "collectd-mod-iwinfo"               # 无线信号强度采集模块
)

# 【7. 硬件级辅助工具】
PKG_HW_TOOLS=(
    "pciutils"                          # PCI 设备查询工具 (使用 lspci 命令查看主板插了啥硬件)
    "iperf3"                            # 局域网极限带宽测速工具 (测试 2.5G 网卡能不能跑满必备)
    "intel-microcode"                   # Intel CPU 微代码更新包 (修复旧版 CPU 漏洞，提升底层稳定性)
)

# 【8. LuCI 网页后台应用扩展】
PKG_LUCI_APPS=(
    "luci-app-openclash"                # 科学上网王者级插件 (功能全面，规则强大)
    "luci-app-homeproxy"                # 新一代轻量科学上网插件 (使用 sing-box 核心，极其轻量迅速)
    "luci-i18n-homeproxy-zh-cn"         # HomeProxy 【中文语言包】
    "luci-theme-argon"                  # Argon 现代美观主题
    "luci-app-ksmbd"                    # 现代轻量级网络共享协议 (Samba 的高性能替代品)
    "luci-i18n-ksmbd-zh-cn"             # ksmbd 【中文语言包】
    "luci-app-statistics"               # 路由器状态实时监控与历史统计图表面板
    "luci-i18n-statistics-zh-cn"        # 统计图表面板 【中文语言包】
    "luci-app-autoreboot"               # 计划任务定时重启插件 (保持系统长期运行流畅)
    "luci-i18n-autoreboot-zh-cn"        # 定时重启 【中文语言包】
)

# 动态加载 Docker 包
PKG_DOCKER=()
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PKG_DOCKER=(
        "dockerd"
        "docker-compose"
        "luci-app-dockerman"
        "luci-i18n-dockerman-zh-cn"
    )
fi

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

echo "=== 6. 开始 Make Image 打包 ==="
# 把 EXTRA_IMAGE_NAME="efi" 改成了 "efi-Deluxe"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-Deluxe" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo "=== 7. 提取固件 ==="
mkdir -p output-firmware
# 拷贝固件时的匹配名字也加上 -Deluxe
cp bin/targets/x86/64/*combined-efi-Deluxe.img.gz output-firmware/ 2>/dev/null || true
echo "=== 全部构建任务已圆满完成！ ==="
