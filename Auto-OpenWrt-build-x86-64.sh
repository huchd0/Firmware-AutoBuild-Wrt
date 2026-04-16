#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量 (支持本地独立运行时的默认值)
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
  MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

echo ">>> 1. 自定义固件参数 <<<"
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

echo ">>> 2. 准备初始化文件夹 <<<"
mkdir -p files/root
mkdir -p files/etc/uci-defaults

echo ">>> 3. 下载第三方插件与 OpenClash 核心 (智能适配 IPK/APK) <<<"
# 自动判断当前编译的是新版(apk)还是旧版(ipk)
if [[ "$OWRT_VERSION" == *"24.10"* ]] || [[ "$OWRT_VERSION" == *"25."* ]] || [[ "$OWRT_VERSION" == *"SNAPSHOT"* ]]; then
    PKG_EXT="apk"
else
    PKG_EXT="ipk"
fi
echo "当前 OpenWrt 版本为 $OWRT_VERSION，使用包后缀: $PKG_EXT"

OPENCLASH_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.${PKG_EXT}" | cut -d '"' -f 4)
if [ -n "$OPENCLASH_URL" ]; then
    echo "正在下载 OpenClash..."
    wget -qO files/root/luci-app-openclash.${PKG_EXT} "$OPENCLASH_URL"
fi

ARGON_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.${PKG_EXT}" | cut -d '"' -f 4)
if [ -n "$ARGON_URL" ]; then
    echo "正在下载 Argon 主题..."
    wget -qO files/root/luci-theme-argon.${PKG_EXT} "$ARGON_URL"
fi

# 提前下载并注入 OpenClash Meta 兼容版内核
echo "正在下载 OpenClash Meta 兼容版内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

echo ">>> 4. 编写全自动开机初始化脚本 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# --- A. 核心网络设置 ---
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# --- 系统基础设置 (时区与主机名) ---
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

# --- C. 智能大分区挂载保护 (动态抓取 UUID) ---
TARGET_DEV=""
if [ -b "/dev/nvme0n1p3" ]; then
    TARGET_DEV="/dev/nvme0n1p3"
elif [ -b "/dev/sda3" ]; then
    TARGET_DEV="/dev/sda3"
fi

if [ -n "\$TARGET_DEV" ]; then
    TARGET_UUID=\$(blkid -s UUID -o value "\$TARGET_DEV")
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
    fi
fi

# --- D. 软件源换源与双引擎插件安装 ---
if command -v apk >/dev/null 2>&1; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null
    apk add -q --allow-untrusted /root/*.apk
elif command -v opkg >/dev/null 2>&1; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/opkg/distfeeds.conf 2>/dev/null
    opkg install /root/*.ipk
fi
rm -f /root/*.apk /root/*.ipk

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- E. 全自动静默升级与定时任务 (双引擎自适应版) ---
echo "正在生成自动升级脚本与定时任务..."

# 🌟 修复点：必须提前创建目录，否则下面写入文件会报错中断
mkdir -p files/usr/bin

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

# 写入定时任务
mkdir -p files/etc/crontabs
echo "0 2 */2 * * /usr/bin/upg" > files/etc/crontabs/root
echo "" >> files/etc/crontabs/root

# 🎯 赋予 crontab 正确的安全权限 (600)，否则计划任务会失效
chmod 0600 files/etc/crontabs/root

echo ">>> 5. 配置官方软件列表 <<<"

declare -a PKG_LIST=(
    # 🌐 1. 核心网络控制
    "-dnsmasq"                          # [卸载] 自带的简配版 dnsmasq
    "dnsmasq-full"                      # [安装] 功能完整的 dnsmasq-full (OpenClash 等强依赖)

    # 🖥️ 2. Web 管理界面 (LuCI) & 全局中文
    "luci"                              # 基础框架界面
    "luci-base"                         # LuCI 底层依赖
    "luci-compat"                       # LuCI 兼容包
    "luci-i18n-base-zh-cn"              # 基础设置中文包
    "luci-i18n-firewall-zh-cn"          # 防火墙中文包
    "luci-i18n-package-manager-zh-cn"   # 软件包管理器中文包

    # 🔌 3. 实用功能插件
    "luci-app-ttyd"                     # 网页版命令行终端
    "luci-i18n-ttyd-zh-cn"              # 终端中文包
    "luci-app-ksmbd"                    # 局域网文件共享
    "luci-i18n-ksmbd-zh-cn"             # 共享中文包

    # 💾 4. 磁盘管理与分区工具 (扩容与 Docker 必备)
    "block-mount"                       # 自动挂载工具
    "blkid"                             # 查看磁盘 UUID
    "lsblk"                             # 列出系统磁盘信息
    "parted"                            # 高级磁盘分区工具
    "fdisk"                             # 基础磁盘分区工具
    "e2fsprogs"                         # ext4 格式化工具

    # 💽 5. 存储设备驱动 & 文件系统支持
    "kmod-usb-storage"                  # USB 存储核心驱动
    "kmod-usb-storage-uas"              # USB UASP 协议加速驱动
    "kmod-fs-ext4"                      # EXT4 格式支持
    "kmod-fs-ntfs3"                     # NTFS 格式支持
    "kmod-fs-vfat"                      # FAT/FAT32 格式支持

    # ⚙️ 6. 核心底层依赖 (OpenClash 等代理插件所需)
    "coreutils-nohup"                   # 后台运行支持
    "bash"                              # 强大的终端 Shell
    "curl"                              # 网络请求下载工具
    "ca-bundle"                         # 根证书 (HTTPS必备)
    "ip-full"                           # 完整版 IP 路由控制
    "iptables-mod-tproxy"               # iptables 透明代理模块
    "iptables-mod-extra"                # iptables 额外模块
    "kmod-tun"                          # TUN 虚拟网卡驱动
    "kmod-inet-diag"                    # 网络连接诊断驱动
    "kmod-nft-tproxy"                   # nftables 透明代理模块
    "libcap"                            # 权限管理核心
    "libcap-bin"                        # 权限管理工具
    "ruby"                              # Ruby 运行环境
    "ruby-yaml"                         # Ruby YAML 解析
    "unzip"                             # 解压缩工具

    # 💻 7. 物理网卡驱动 & 无线工具
    "kmod-igc"                          # Intel i225/i226 2.5G 网卡驱动
    "iwinfo"                            # 无线网络信息查看工具
)

PACKAGES="${PKG_LIST[*]}"

echo ">>> 6. 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo ">>> 7. 提取并重命名固件 <<<"
mkdir -p output-firmware

# 寻找编译好的固件，复制并加上 Auto- 前缀
for file in bin/targets/x86/64/*combined-efi.img.gz; do
  if [ -f "$file" ]; then
    filename=$(basename "$file")
    cp "$file" "output-firmware/Auto-$filename"
    echo "✅ 成功生成并重命名: Auto-$filename"
  fi
done

echo ">>> 全部构建任务已圆满完成！ <<<"
