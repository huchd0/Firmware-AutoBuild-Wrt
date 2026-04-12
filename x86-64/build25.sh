#!/bin/bash
set -e

# 终端输出颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

echo "========================================================="
echo -e "🕒 [$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}开始构建流程...${NC}"
echo "========================================================="

# =========================================================
# 0. 自定义底层固件参数 (锁定 64MB 内核分区)
# =========================================================
echo -e "${YELLOW}⚙️ 正在精简固件配置并锁定内核分区大小...${NC}"
cat >> .config <<EOF
CONFIG_TARGET_KERNEL_PARTSIZE=64
CONFIG_TARGET_ROOTFS_EXT4FS=n
CONFIG_TARGET_ROOTFS_TARGZ=n
CONFIG_VMDK_IMAGES=n
CONFIG_VDI_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_QCOW2_IMAGES=n
CONFIG_ISO_IMAGES=n
EOF
echo "✅ 底层配置参数写入完成。"

# =========================================================
# 1. 软件包组合策略
# =========================================================
# 基础包与网卡驱动 (确保多网口全识别)
BASE_PKGS="curl wget iperf3 luci-i18n-diskman-zh-cn luci-i18n-filemanager-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server kmod-igb kmod-e1000e kmod-r8169 kmod-igc"

# 主题包 (强制装入 Argon)
THEME_PKGS="luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"

# 网络与防火墙包
NET_PKGS="luci-i18n-firewall-zh-cn luci-i18n-upnp-zh-cn luci-i18n-autoreboot-zh-cn"

# OpenClash 及其必需底层依赖
PROXY_PKGS="luci-app-openclash coreutils-nohup bash dnsmasq-full ipset ip-full libcap libcap-bin ruby ruby-yaml unzip kmod-tun"

# Docker 包组合 (兼容 24.10/25.12 apk 系统)
DOCKER_PKGS=""
if [ "$INCLUDE_DOCKER" == "yes" ]; then
    echo -e "${YELLOW}🐳 已开启 Docker 支持，正在追加相关依赖包...${NC}"
    DOCKER_PKGS="luci-app-dockerman luci-i18n-dockerman-zh-cn docker docker-compose dockerd kmod-veth"
fi

PACKAGES="$BASE_PKGS $THEME_PKGS $NET_PKGS $PROXY_PKGS $DOCKER_PKGS"

# =========================================================
# 2. OpenClash 核心预集成 (增强鲁棒性)
# =========================================================
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo -e "${YELLOW}⬇️ 正在为 OpenClash 下载 Meta 核心...${NC}"
    CORE_PATH="files/etc/openclash/core"
    mkdir -p "$CORE_PATH"
    
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    
    # 使用 curl 强力下载，并解压校验
    if curl -sL --connect-timeout 10 --max-time 30 -o clash.tar.gz "$META_URL"; then
        tar -zxf clash.tar.gz -C "$CORE_PATH"
        # 确保文件存在再重命名并赋权
        if [ -f "$CORE_PATH/clash" ]; then
            mv "$CORE_PATH/clash" "$CORE_PATH/clash_meta"
            chmod +x "$CORE_PATH/clash_meta"
            echo -e "${GREEN}✅ OpenClash Meta 核心预装成功！${NC}"
        else
            echo -e "${YELLOW}⚠️ 解压后未找到 clash 文件，核心集成失败。${NC}"
        fi
        rm -f clash.tar.gz
    else
        echo -e "${YELLOW}⚠️ 核心下载失败或超时，请刷机后在路由器后台手动点击更新。${NC}"
    fi
fi

# =========================================================
# 3. 动态系统初始化脚本 (99-init-settings)
# =========================================================
mkdir -p files/etc/uci-defaults

cat << 'EOF' > files/etc/uci-defaults/99-init-settings
#!/bin/sh

# [1] 提取 IP 配置
[ -f /etc/config/custom_router_ip.txt ] && CUSTOM_IP=$(cat /etc/config/custom_router_ip.txt) || CUSTOM_IP="192.168.100.1"

# ====================================================
# [2] 核心逻辑：智能动态网口分配 (WAN/LAN 桥接)
# ====================================================
# 抓取系统中所有真实的物理以太网卡 (排除 lo, wlan, veth 等)
PHYSICAL_IFACES=$(ls /sys/class/net | grep -E '^eth[0-9]+$|^enp[0-9]+s[0-9]+$' | sort)
IFACE_COUNT=$(echo "$PHYSICAL_IFACES" | wc -w)

if [ "$IFACE_COUNT" -eq 1 ]; then
    # 🌟 单网口模式：作为旁路由/单臂路由 (只有 LAN，没有 WAN)
    ONLY_IFACE=$(echo "$PHYSICAL_IFACES" | awk '{print $1}')
    [ -z "$ONLY_IFACE" ] && ONLY_IFACE="eth0"
    
    uci set network.lan.device="$ONLY_IFACE"
    uci delete network.lan.type # 单网口不需要桥接
    
    # 彻底删除 WAN 接口
    uci -q delete network.wan
    uci -q delete network.wan6
    
elif [ "$IFACE_COUNT" -gt 1 ]; then
    # 🌟 多网口模式：第一个口为 WAN，其余所有口桥接为 LAN
    WAN_IFACE=$(echo "$PHYSICAL_IFACES" | awk '{print $1}')
    
    # 将除了 WAN 口之外的所有网口提取出来
    LAN_IFACES=$(echo "$PHYSICAL_IFACES" | sed "s/\b$WAN_IFACE\b//" | xargs)
    
    # 配置 WAN 口
    uci set network.wan.device="$WAN_IFACE"
    uci set network.wan6.device="$WAN_IFACE"
    
    # 配置 LAN 口 (开启桥接，并将所有剩余网卡加入桥接)
    uci set network.lan.type='bridge'
    uci set network.lan.device="$LAN_IFACES"
else
    # 兜底防呆方案
    uci set network.lan.device="eth0"
fi

# 写入 LAN 口的 IP 和【修复：死锁 255.255.255.0 子网掩码】
uci set network.lan.ipaddr="$CUSTOM_IP"
uci set network.lan.netmask="255.255.255.0"
# ====================================================

# [3] 宽带拨号与 Docker 规则 (读取环境变量)
if [ -f /etc/config/build_env.txt ]; then
    . /etc/config/build_env.txt
    
    # 如果是多网口(存在WAN口)，才执行宽带账号注入
    if uci -q get network.wan >/dev/null; then
        if [ -n "$PPPOE_ACCOUNT" ] && [ -n "$PPPOE_PASSWORD" ]; then
            uci set network.wan.proto='pppoe'
            uci set network.wan.username="$PPPOE_ACCOUNT"
            uci set network.wan.password="$PPPOE_PASSWORD"
            uci set network.wan.ipv6='1'
        fi
    fi

    # Docker 网络打通
    if [ "$INCLUDE_DOCKER" = "yes" ]; then
        uci set network.docker=interface
        uci set network.docker.proto='none'
        uci set network.docker.device='docker0'

        uci set firewall.docker=zone
        uci set firewall.docker.name='docker'
        uci set firewall.docker.network='docker'
        uci set firewall.docker.input='ACCEPT'
        uci set firewall.docker.output='ACCEPT'
        uci set firewall.docker.forward='ACCEPT'

        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='docker'
        uci set firewall.@forwarding[-1].dest='wan'

        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='docker'
        
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='docker'
        uci set firewall.@forwarding[-1].dest='lan'
    fi
fi

# [4] 强制激活 Argon 主题
uci set luci.main.mediaurlbase='/luci-static/argon'

# 提交所有更改
uci commit network
uci commit firewall
uci commit luci

# 清理痕迹，完成无痕部署
rm -f /etc/config/custom_router_ip.txt
rm -f /etc/config/build_env.txt
rm -f /etc/uci-defaults/99-init-settings
exit 0
EOF

chmod +x files/etc/uci-defaults/99-init-settings

# =========================================================
# 4. 传递 YAML 环境变量给开机脚本
# =========================================================
echo "PPPOE_ACCOUNT='$PPPOE_ACCOUNT'" > files/etc/config/build_env.txt
echo "PPPOE_PASSWORD='$PPPOE_PASSWORD'" >> files/etc/config/build_env.txt
echo "INCLUDE_DOCKER='$INCLUDE_DOCKER'" >> files/etc/config/build_env.txt

# =========================================================
# 5. 执行镜像打包
# =========================================================
echo -e "${BLUE}🛠️ 正在调用镜像构建器打包固件...${NC}"

# 加入 KERNEL_PARTSIZE=64 双重保险
make image PROFILE="generic" \
           PACKAGES="$PACKAGES" \
           FILES="files" \
           EXTRA_IMAGE_NAME="efi" \
           KERNEL_PARTSIZE=64 \
           ROOTFS_PARTSIZE="${ROOTFS_SIZE:-1024}" \
           -j$(nproc)

echo "========================================================="
echo -e "🎉 [$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}固件编译成功！${NC}"
echo "========================================================="
