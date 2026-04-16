#!/bin/bash

# =========================================================
# 0. 云端预处理：预下载 OpenClash 兼容版核心 (解决 Illegal Instruction)
# =========================================================
mkdir -p files/etc/openclash/core
if [ "$APP_OPENCLASH" = "true" ]; then
    echo ">>> 正在下载 OpenClash Meta 兼容版内核..."
    CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
    curl -sL --retry 3 "$CORE_URL" -o meta.tar.gz
    if tar -tzf meta.tar.gz >/dev/null 2>&1; then
        tar -xOzf meta.tar.gz > files/etc/openclash/core/clash_meta
        chmod +x files/etc/openclash/core/clash_meta
        rm -f meta.tar.gz
    fi
fi

# =========================================================
# 1. 初始化脚本与必备工具
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"
echo "#!/bin/sh" > $DYNAMIC_SCRIPT

# 强化工具包
BASE_PACKAGES="base-files block-mount default-settings-chn luci-i18n-base-zh-cn sgdisk parted e2fsprogs fdisk lsblk blkid tar"
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-package-manager-zh-cn htop curl wget-ssl kmod-vmxnet3"

# =========================================================
# 🌟 核心魔法：暴力重建网络、安全强制扩容、只读解除
# =========================================================
cat >> $DYNAMIC_SCRIPT << EOF
# 解除系统只读状态 (防止配置无法保存)
mount -o remount,rw /

# --- A. 彻底推倒重建网络配置 (消灭 Ghost eth0) ---
INTERFACES=\$(ls /sys/class/net 2>/dev/null | grep -E '^eth|^enp|^eno' | sort)
ETH_COUNT=\$(echo "\$INTERFACES" | grep -c '^')

if [ "\$ETH_COUNT" -gt 0 ]; then
    FIRST_ETH=\$(echo "\$INTERFACES" | head -n 1)
    
    # 彻底抹除旧配置
    rm -f /etc/config/network
    touch /etc/config/network
    
    # 重新生成最纯净的基础配置
    uci set network.loopback=interface
    uci set network.loopback.device='lo'
    uci set network.loopback.proto='static'
    uci set network.loopback.ipaddr='127.0.0.1'
    uci set network.loopback.netmask='255.0.0.0'
    
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    
    uci set network.lan=interface
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='$CUSTOM_IP'
    uci set network.lan.netmask='255.255.255.0'

    if [ "\$ETH_COUNT" -eq 1 ]; then
        uci add_list network.br_lan.ports="\$FIRST_ETH"
    else
        # eth0 为 WAN，其余为 LAN
        uci set network.wan=interface
        uci set network.wan.device="\$FIRST_ETH"
        uci set network.wan.proto='dhcp'
        
        uci set network.wan6=interface
        uci set network.wan6.device="\$FIRST_ETH"
        uci set network.wan6.proto='dhcpv6'

        for eth in \$(echo "\$INTERFACES" | grep -v "^\$FIRST_ETH\$"); do
            uci add_list network.br_lan.ports="\$eth"
        done
    fi
    uci commit network
fi

# --- B. 强制磁盘同步与 10GB 扩容 (sda2) ---
ROOT_DISK=\$(lsblk -d -n -o NAME | grep -E 'sda|nvme[0-9]n[0-9]' | head -n 1)
if [ -n "\$ROOT_DISK" ]; then
    DISK_DEV="/dev/\$ROOT_DISK"
    echo "\$ROOT_DISK" | grep -q "nvme" && P2="\${DISK_DEV}p2" && P3="\${DISK_DEV}p3" || P2="\${DISK_DEV}2" && P3="\${DISK_DEV}3"

    # 1. 修复 GPT 表
    sgdisk -e \$DISK_DEV || true
    sync && sleep 2

    # 2. 扩容分区表
    parted -s \$DISK_DEV resizepart 2 ${ROOTFS_SIZE}MiB || true
    sync && sleep 2
    
    # 3. 强制触发内核刷新分区表缓存
    if command -v partx >/dev/null; then
        partx -u \$DISK_DEV || true
    fi
    
    # 4. 在线拉伸文件系统 (关键：确保系统盘不再是 1GB)
    resize2fs \$P2 || true
    sync

    # --- C. 数据盘安全检测挂载 (sda3) ---
    if [ -b "\$P3" ]; then
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
            mount \$P3 /opt 2>/dev/null || true
            
            if mountpoint -q /opt; then
                [ ! -f /opt/backup/factory_config.tar.gz ] && tar -czf /opt/backup/factory_config.tar.gz /etc/config /etc/passwd /etc/shadow 2>/dev/null
            fi
        fi
    fi
fi

# 注入恢复指令
cat > /bin/restore-factory << 'RE'
#!/bin/sh
if [ -f /opt/backup/factory_config.tar.gz ]; then
    rm -rf /etc/config/*
    tar -xzf /opt/backup/factory_config.tar.gz -C /
    reboot
else
    echo "未发现备份，请确认 /opt 挂载。"
fi
RE
chmod +x /bin/restore-factory
EOF

# =========================================================
# 2. 插件选择
# =========================================================
BASE_PACKAGES="$BASE_PACKAGES irqbalance iperf3 luci-i18n-package-manager-zh-cn"
[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
[ "$INCLUDE_DOCKER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"

# =========================================================
# 4. 极致打包：只保留 ext4-EFI，禁止生成其他冗余格式
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=1024/g" .config || echo "CONFIG_TARGET_ROOTFS_PARTSIZE=1024" >> .config
sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config || echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config

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
