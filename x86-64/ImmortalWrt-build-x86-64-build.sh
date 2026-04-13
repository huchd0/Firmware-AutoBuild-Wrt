#!/bin/bash
set -e

echo "========== 开始 GitHub 高速构建 (纯离线防崩版) =========="

# 1. IP 与 掩码处理
# 接收传入的 IP，如果没有则默认 192.168.100.1
INPUT_IP=${MANAGEMENT_IP:-192.168.100.1}
# 强行剥离可能带有的 /24，确保提取出纯 IP (如 192.168.100.1)
IP_ADDR=$(echo "$INPUT_IP" | cut -d'/' -f1)
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}

# 强制内核分区为 64MB，RootFS 为用户指定大小
sed -i '/CONFIG_TARGET_KERNEL_PARTSIZE/d' .config
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
sed -i '/CONFIG_TARGET_ROOTFS_PARTSIZE/d' .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

# 2. 准备目录结构
# 增加 config 目录用于强制写入底层网络配置
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core files/etc/config

# 3. 极速拉取 OpenClash (利用 GitHub 海外网络优势)
echo ">>> [GitHub 云端] 正在拉取 OpenClash 插件与 Meta 核心..."
# 自动抓取 OpenClash 最新版 IPK
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

# 拉取 Meta 核心并重命名，防止初次运行找不到核心
META_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
wget -qO- "$META_CORE_URL" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta

# 4. 暴力注入默认网络配置 (终极保险，防止开机脚本失效)
# 这一步直接将配置刻入系统镜像，确保开机默认 IP 和基础桥接绝对正确
cat << EOF > files/etc/config/network
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fdc9:e120:3917::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '$IP_ADDR'
	option netmask '255.255.255.0'
EOF

# 5. 编写纯本地初始化脚本 (去除一切联网操作，杜绝卡死)
cat << 'EOF' > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 开启执行日志记录到 /root/setup-network.log，方便后期排错
exec > /root/setup-network.log 2>&1
set -x

# --- 1. IP、掩码与主机名复核 ---
uci set network.lan.ipaddr='REPLACE_IP_ADDR'
uci set network.lan.netmask='255.255.255.0'
uci set system.@system[0].hostname='Tanxm'

# --- 2. 严格网口分配 (单口/多口自适应) ---
# 获取所有真实物理网口
INTERFACES=$(ls /sys/class/net | grep -E '^e(th|n)' | sort)
INT_COUNT=$(echo "$INTERFACES" | wc -w)

# 先清空默认的桥接端口
uci del_list network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'

if [ "$INT_COUNT" -gt 1 ]; then
    # 【多口模式】：设置 eth0 为 WAN 口
    uci set network.wan=interface
    uci set network.wan.device='eth0'
    uci set network.wan.proto='dhcp'

    uci set network.wan6=interface
    uci set network.wan6.device='eth0'
    uci set network.wan6.proto='dhcpv6'

    # 将除 eth0 以外的剩余口加入 LAN 桥接
    for iface in $INTERFACES; do
        if [ "$iface" != "eth0" ]; then
            uci add_list network.@device[0].ports="$iface"
        fi
    done
else
    # 【单口模式】：删除所有 WAN 配置，唯一的 eth0 归 LAN
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
    uci add_list network.@device[0].ports='eth0'
fi
uci commit network

# --- 3. sda3 磁盘安全处理 (智能分区与挂载) ---
# 检查是否已有 sda3
if ! ls /dev/sda3 >/dev/null 2>&1; then
    echo ">>> 检测到首次运行，正在创建并格式化 sda3 分区..."
    (echo n; echo 3; echo; echo; echo w) | fdisk /dev/sda
    sync && mkfs.ext4 /dev/sda3
fi
# 无论是否新建，都执行挂载逻辑
REAL_UUID=$(blkid -s UUID -o value /dev/sda3)
if [ -n "$REAL_UUID" ] && ! uci show fstab | grep -q "$REAL_UUID"; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 4. 杂项与拥塞控制 ---
# 开启 BBR
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# 切换为国内优质 NTP 服务器
uci delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# --- 5. 纯离线安装插件 ---
# 跳过 opkg update，直接本地暴力安装预埋的 OpenClash
if [ -f "/root/luci-app-openclash.ipk" ]; then
    opkg install /root/luci-app-openclash.ipk
    rm -f /root/luci-app-openclash.ipk
fi

# 脚本执行完毕，删掉自己，重启网络使配置生效
rm -f /etc/uci-defaults/99-custom-setup
/etc/init.d/network restart
exit 0
EOF

# 注入真实 IP 变量并赋予执行权限
sed -i "s|REPLACE_IP_ADDR|$IP_ADDR|g" files/etc/uci-defaults/99-custom-setup
chmod +x files/etc/uci-defaults/99-custom-setup

# 6. 终极软件包清单 (一揽子打包所有依赖，实现纯离线)
echo ">>> 定义软件包..."
# 强烈注意：这里加入了 luci-theme-argon 和 OpenClash 的所有底层依赖
PACKAGES="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd \
block-mount blkid lsblk parted fdisk e2fsprogs coreutils-nohup bash curl ca-bundle \
ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun unzip iwinfo \
libcap-bin ca-certificates kmod-inet-diag kmod-tcp-bbr luci-theme-argon"

# 7. 执行编译
echo ">>> 正在执行 Make Image 编译..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo "========== 固件构建完成 =========="
