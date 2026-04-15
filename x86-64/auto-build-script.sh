#!/bin/bash

# =========================================================
# 0. 准备动态初始化脚本 (按需生成相关配置)
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"

echo "#!/bin/sh" > $DYNAMIC_SCRIPT
echo "uci set network.lan.ipaddr='$CUSTOM_IP'" >> $DYNAMIC_SCRIPT

# =========================================================
# 1. 隐式底层强化包 (扩容魔法与性能优化必备)
# =========================================================
BASE_PACKAGES=""
# 系统核心与磁盘管理 (补全了 util-linux-lsblk 确保硬件抓取不报错)
BASE_PACKAGES="$BASE_PACKAGES base-files block-mount default-settings-chn luci-i18n-base-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES sgdisk parted e2fsprogs fdisk lsblk blkid"
# 性能优化工具
BASE_PACKAGES="$BASE_PACKAGES irqbalance zram-swap iperf3 htop curl wget-ssl kmod-vmxnet3"
# 隐式预装小工具 (免界面勾选)
BASE_PACKAGES="$BASE_PACKAGES luci-app-ttyd luci-i18n-ttyd-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-upnp luci-i18n-upnp-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-wol luci-i18n-wol-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-ramfree luci-i18n-ramfree-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-autoreboot luci-i18n-autoreboot-zh-cn"

# =========================================================
# 🌟 终极魔法：开机自动拉伸 RootFS，并用 UUID 挂载数据持久盘
# =========================================================
# 在云端提前计算好 P3 的安全起始偏移量 (+1MiB 杜绝分区重叠报错)
START_MB=$(( ROOTFS_SIZE + 1 ))

# 注意：这里使用双引号 "EOF"，是为了让 $ROOTFS_SIZE 等云端变量在此刻被直接写入脚本
cat >> $DYNAMIC_SCRIPT << EOF
# 1. 智能抓取主硬盘
ROOT_DISK=\$(lsblk -d -n -o NAME | grep -E 'sda|nvme[0-9]n[0-9]' | head -n 1)

if [ -n "\$ROOT_DISK" ]; then
    DISK_DEV="/dev/\$ROOT_DISK"
    
    # 适配 SATA 与 NVMe 的分区命名后缀
    if echo "\$ROOT_DISK" | grep -q "nvme"; then
        P2="\${DISK_DEV}p2"
        P3="\${DISK_DEV}p3"
    else
        P2="\${DISK_DEV}2"
        P3="\${DISK_DEV}3"
    fi

    # 2. 修复 GPT 备份表，释放硬盘末尾空间
    sgdisk -e \$DISK_DEV
    sync && sleep 1

    # 3. 强行拉伸系统盘 (P2) 至用户目标容量
    parted -s \$DISK_DEV resizepart 2 ${ROOTFS_SIZE}MiB
    sync && sleep 1
    resize2fs \$P2

    # 4. 判断数据盘 (P3) 是否存在 (实现跨版本刷机保留数据)
    if ! lsblk \$P3 >/dev/null 2>&1; then
        # 仅在第一次刷机时，创建第三分区并格式化
        parted -s \$DISK_DEV mkpart primary ext4 ${START_MB}MiB 100%
        sync && sleep 2
        mkfs.ext4 -F \$P3
        sync && sleep 1
    fi

    # 5. 最稳健的 UUID 挂载逻辑 (防止硬盘插拔乱序)
    P3_UUID=\$(blkid -s UUID -o value \$P3)
    if [ -n "\$P3_UUID" ]; then
        # 删除旧的 opt_mount 防止重复，强制更新
        uci -q delete fstab.opt_mount || true
        uci set fstab.opt_mount='mount'
        uci set fstab.opt_mount.uuid="\$P3_UUID"
        uci set fstab.opt_mount.target='/opt'
        uci set fstab.opt_mount.fstype='ext4'
        uci set fstab.opt_mount.enabled='1'
        uci commit fstab
    fi

    # 6. 提前建好储物间，并尝试在开机第一秒立即挂载
    mkdir -p /opt/docker /opt/alist /opt/downloads /opt/smb
    mount \$P3 /opt 2>/dev/null || true
fi
EOF

# =========================================================
# 2. 根据界面勾选，动态追加功能
# =========================================================
[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon" && echo "uci set luci.main.mediaurlbase='/luci-static/argon'" >> $DYNAMIC_SCRIPT
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_PASSWALL" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"
[ "$APP_KSMBD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn" && echo "uci set ksmbd.globals.workgroup='WORKGROUP'" >> $DYNAMIC_SCRIPT
[ "$APP_ALIST" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"
[ "$APP_QBITTORRENT" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"
[ "$APP_ADGUARDHOME" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-adguardhome"
[ "$APP_MWAN3" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-mwan3 luci-i18n-mwan3-zh-cn"
[ "$APP_VLMCSD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-vlmcsd luci-i18n-vlmcsd-zh-cn" && echo "uci set vlmcsd.config.enabled='1'" >> $DYNAMIC_SCRIPT
[ "$APP_STATISTICS" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory collectd-mod-network"
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
# 4. 封装配置、锁死底层体积、砍掉无用格式并执行编译
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

# 🎯 锁死云端出包为 1024MB，装下海量插件
if grep -q "CONFIG_TARGET_ROOTFS_PARTSIZE" .config; then
    sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=1024/g" .config
else
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=1024" >> .config
fi

# 🛡️ 锁死内核分区为 64MB，确保未来重刷数据盘不偏移
if grep -q "CONFIG_TARGET_KERNEL_PARTSIZE" .config; then
    sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config
else
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
fi

# ✂️ 极致精简输出：只保留 ext4，砍掉 squashfs 和所有虚拟机格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=y" >> .config      # 必须保留 ext4 (扩容魔法的基石)
echo "CONFIG_TARGET_ROOTFS_SQUASHFS=n" >> .config    # 砍掉 squashfs
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config       # 砍掉 .tar.gz 备份包
echo "CONFIG_VDI_IMAGES=n" >> .config                # 砍掉 VirtualBox 格式
echo "CONFIG_VMDK_IMAGES=n" >> .config               # 砍掉 VMware 格式
echo "CONFIG_VHDX_IMAGES=n" >> .config               # 砍掉 Hyper-V 格式
echo "CONFIG_QCOW2_IMAGES=n" >> .config              # 砍掉 QEMU 格式
echo "CONFIG_ISO_IMAGES=n" >> .config                # 砍掉 ISO 镜像

echo ">>> 最终打包的软件列表: $BASE_PACKAGES"

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
