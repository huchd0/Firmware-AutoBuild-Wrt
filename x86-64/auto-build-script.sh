#!/bin/bash

# =========================================================
# 0. 云端预处理：预下载 OpenClash 核心 (增强容错处理)
# =========================================================
mkdir -p files/etc/openclash/core
if [ "$APP_OPENCLASH" = "true" ]; then
    echo ">>> 正在下载 OpenClash Meta 内核..."
    curl -sL --retry 3 "https://raw.githubusercontent.com/vernesong/OpenClash/master/resources/overrides/clash_meta.tar.gz" -o clash_meta.tar.gz
    if [ -f "clash_meta.tar.gz" ]; then
        tar -zxf clash_meta.tar.gz -C files/etc/openclash/core
        chmod +x files/etc/openclash/core/clash_meta
        rm -f clash_meta.tar.gz
    else
        echo "⚠️ 警告: OpenClash 内核下载失败，请开机后手动更新。"
    fi
fi

# =========================================================
# 1. 准备初始化脚本与强化包
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"
echo "#!/bin/sh" > $DYNAMIC_SCRIPT

BASE_PACKAGES=""
# 磁盘与备份核心 (移除了不存在的 partprobe)
BASE_PACKAGES="$BASE_PACKAGES base-files block-mount default-settings-chn luci-i18n-base-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES sgdisk parted e2fsprogs fdisk lsblk blkid tar"
# 基础中文支持与包管理器
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-package-manager-zh-cn"

# =========================================================
# 🌟 核心魔法：智能接口分配、安全扩容、数据防毁挂载
# =========================================================
cat >> $DYNAMIC_SCRIPT << EOF
# --- A. 智能接口分配 (容错机制：防止无网卡导致脚本崩溃) ---
INTERFACES=\$(ls /sys/class/net 2>/dev/null | grep -E '^eth|^enp|^eno' | sort)
ETH_COUNT=\$(echo "\$INTERFACES" | grep -c '^')

if [ "\$ETH_COUNT" -gt 0 ]; then
    FIRST_ETH=\$(echo "\$INTERFACES" | head -n 1)
    
    # 设定默认 IP 与子网掩码
    uci set network.lan.ipaddr='$CUSTOM_IP'
    uci set network.lan.netmask='255.255.255.0'

    if [ "\$ETH_COUNT" -eq 1 ]; then
        # 单网口模式：删除 WAN，全量转为 LAN
        uci delete network.wan 2>/dev/null
        uci delete network.wan6 2>/dev/null
        uci set network.lan.device="\$FIRST_ETH"
    else
        # 多网口模式：FIRST_ETH 拨号，其余桥接
        uci set network.wan=interface
        uci set network.wan.proto='dhcp'
        uci set network.wan.device="\$FIRST_ETH"

        uci set network.wan6=interface
        uci set network.wan6.proto='dhcpv6'
        uci set network.wan6.device="\$FIRST_ETH"

        OTHER_ETHS=\$(echo "\$INTERFACES" | sed '1d' | tr '\n' ' ')
        uci set network.lan.ports="\$OTHER_ETHS"
    fi
    uci commit network
fi

# --- B. 根文件系统强制且安全的扩容 (sda2) ---
ROOT_DISK=\$(lsblk -d -n -o NAME | grep -E 'sda|nvme[0-9]n[0-9]' | head -n 1)
if [ -n "\$ROOT_DISK" ]; then
    DISK_DEV="/dev/\$ROOT_DISK"
    echo "\$ROOT_DISK" | grep -q "nvme" && P2="\${DISK_DEV}p2" && P3="\${DISK_DEV}p3" || P2="\${DISK_DEV}2" && P3="\${DISK_DEV}3"

    # 1. 修复 GPT 表并利用 sync 强制内核同步
    sgdisk -e \$DISK_DEV
    sync && sleep 2

    # 2. 扩容系统盘 (尝试拉伸到指定大小，容错：避免超过物理边界报错)
    parted -s \$DISK_DEV resizepart 2 ${ROOTFS_SIZE}MiB || true
    sync && sleep 2
    
    # 3. 文件系统强行自检与在线拉伸 (极其重要的防炸盘机制)
    e2fsck -f -y \$P2
    resize2fs \$P2
    sync

    # --- C. 数据盘安全挂载 (sda3) ---
    # 绝对原则：只查验，不格式化。保障重刷固件时数据完好无损。
    if lsblk \$P3 >/dev/null 2>&1; then
        P3_UUID=\$(blkid -s UUID -o value \$P3)
        if [ -n "\$P3_UUID" ]; then
            uci -q delete fstab.opt_mount || true
            uci set fstab.opt_mount='mount'
            uci set fstab.opt_mount.uuid="\$P3_UUID"
            uci set fstab.opt_mount.target='/opt'
            uci set fstab.opt_mount.fstype='ext4'
            uci set fstab.opt_mount.enabled='1'
            uci commit fstab
            
            mkdir -p /opt/collectd_rrd /opt/backup /opt/docker
            mount \$P3 /opt 2>/dev/null
            
            # --- D. 备份与数据迁移 (容错：挂载成功才执行) ---
            if mountpoint -q /opt; then
                # 打包纯净配置
                [ ! -f /opt/backup/factory_config.tar.gz ] && tar -czf /opt/backup/factory_config.tar.gz /etc/config /etc/passwd /etc/shadow 2>/dev/null
                
                # 迁移统计数据，减少闪存磨损
                if [ -f /etc/config/statistics ]; then
                    uci set statistics.collectd.Datadir='/opt/collectd_rrd'
                    uci commit statistics
                fi
            fi
        fi
    fi
fi

# --- E. 注入系统恢复指令 ---
cat > /bin/restore-factory << 'RE'
#!/bin/sh
echo "========================================="
echo "☢️  正在执行系统恢复操作..."
echo "========================================="
if [ -f /opt/backup/factory_config.tar.gz ]; then
    echo "[1/3] 清理当前异常配置..."
    rm -rf /etc/config/*
    echo "[2/3] 应用出厂纯净配置..."
    tar -xzf /opt/backup/factory_config.tar.gz -C /
    echo "[3/3] 恢复成功，系统即将重启..."
    sleep 2
    reboot
else
    echo "❌ 错误: 未找到备份文件。请确认数据盘(/opt)已正确挂载。"
fi
RE
chmod +x /bin/restore-factory
EOF

# =========================================================
# 2. 插件包动态组装
# =========================================================
BASE_PACKAGES="$BASE_PACKAGES irqbalance zram-swap iperf3 htop curl wget-ssl kmod-vmxnet3"

[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_PASSWALL" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"
[ "$APP_KSMBD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
[ "$APP_ADGUARDHOME" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-adguardhome"
[ "$APP_ALIST" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"
[ "$APP_QBITTORRENT" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"
[ "$APP_MWAN3" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-mwan3 luci-i18n-mwan3-zh-cn"
[ "$APP_VLMCSD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-vlmcsd luci-i18n-vlmcsd-zh-cn"
[ "$APP_STATISTICS" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory"
[ "$APP_SQM" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-sqm luci-i18n-sqm-zh-cn"
[ "$APP_WIREGUARD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-proto-wireguard"
[ "$APP_TAILSCALE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES tailscale"
[ "$APP_ZEROTIER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn"
[ "$APP_FRPC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-frpc luci-i18n-frpc-zh-cn"

[ "$KMOD_IGC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-igc"
[ "$KMOD_IXGBE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-ixgbe"
[ "$KMOD_E1000E" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-e1000e"
[ "$KMOD_R8169" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-r8169"
[ "$KMOD_R8125" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-r8125"
[ "$INCLUDE_DOCKER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"

# =========================================================
# 4. 锁定物理参数并执行极限精简打包
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

# 锁死内核与出厂体积
sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=1024/g" .config || echo "CONFIG_TARGET_ROOTFS_PARTSIZE=1024" >> .config
sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config || echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config

# 极致精简：砍掉所有多余格式，确保仅输出 ext4 EFI
echo "CONFIG_TARGET_ROOTFS_EXT4FS=y" >> .config
echo "CONFIG_TARGET_ROOTFS_SQUASHFS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
