#!/bin/bash
set -e

# 终端输出颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

echo "========================================================="
echo -e "🕒 [$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}开始构建流程...${NC}"
echo -e "📦 目标 RootFS 分区大小: ${GREEN}${ROOTFS_SIZE:-1024} MB${NC}"
echo "========================================================="

# >>> 1. 自定义固件参数 (注入 .config) <<<
echo -e "${YELLOW}⚙️ 正在精简固件配置并设置分区大小...${NC}"

# 使用 cat 一次性注入，避免多次调用 echo 导致 IO 碎片
cat >> .config <<EOF
# 设置内核分区大小
CONFIG_TARGET_KERNEL_PARTSIZE=64
# 禁用不需要的镜像格式 (精简输出)
CONFIG_TARGET_ROOTFS_EXT4FS=n
CONFIG_TARGET_ROOTFS_TARGZ=n
CONFIG_VMDK_IMAGES=n
CONFIG_VDI_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_QCOW2_IMAGES=n
CONFIG_ISO_IMAGES=n
CONFIG_GRUB_IMAGES=n
EOF

echo "✅ 底层配置参数写入完成。"

# >>> 2. 读取外部自定义包列表 <<<
if [ -f "shell/custom-packages.sh" ]; then
    echo "📜 加载自定义包脚本..."
    source shell/custom-packages.sh
fi

# >>> 3. 自动化初始化脚本 (UCI Defaults) <<<
# 读取由 GitHub Actions 映射过来的 IP 地址文件
if [ -f "files/etc/config/custom_router_ip.txt" ]; then
    CUSTOM_ROUTER_IP=$(cat files/etc/config/custom_router_ip.txt)
else
    CUSTOM_ROUTER_IP="192.168.100.1"
fi

echo -e "${YELLOW}🔧 写入系统初始化配置 (LAN IP: $CUSTOM_ROUTER_IP)...${NC}"
INIT_SETTING="files/etc/uci-defaults/99-init-settings"
mkdir -p "$(dirname "$INIT_SETTING")"

# 写入基础网络配置
cat << EOF > "$INIT_SETTING"
#!/bin/sh
# 设置 LAN 口 IP
uci set network.lan.ipaddr='$CUSTOM_ROUTER_IP'
uci commit network
EOF

# 判断并写入 PPPoE 拨号配置
if [ "$ENABLE_PPPOE" == "yes" ]; then
    echo "📝 注入 PPPoE 宽带拨号信息..."
    cat << EOF >> "$INIT_SETTING"

# 设置 WAN 口 PPPoE 拨号
uci set network.wan.proto='pppoe'
uci set network.wan.username='$PPPOE_ACCOUNT'
uci set network.wan.password='$PPPOE_PASSWORD'
uci commit network
EOF
fi

# 判断并写入 Docker 网络和防火墙放行规则
if [ "$INCLUDE_DOCKER" == "yes" ]; then
    echo "🐳 注入 Docker 专属网络与防火墙规则..."
    cat << EOF >> "$INIT_SETTING"

# 1. 注册 Docker 虚拟网卡 (方便在 LuCI 网络界面查看)
uci set network.docker=interface
uci set network.docker.proto='none'
uci set network.docker.device='docker0'
uci commit network

# 2. 创建 Docker 防火墙区域
uci set firewall.docker=zone
uci set firewall.docker.name='docker'
uci set firewall.docker.network='docker'
uci set firewall.docker.input='ACCEPT'
uci set firewall.docker.output='ACCEPT'
uci set firewall.docker.forward='ACCEPT'

# 3. 允许 Docker 容器访问外网 (Docker -> WAN)
uci set firewall.docker_to_wan=forwarding
uci set firewall.docker_to_wan.src='docker'
uci set firewall.docker_to_wan.dest='wan'

# 4. 允许局域网设备访问 Docker 容器 (LAN <-> Docker 双向)
uci set firewall.docker_to_lan=forwarding
uci set firewall.docker_to_lan.src='docker'
uci set firewall.docker_to_lan.dest='lan'
uci set firewall.lan_to_docker=forwarding
uci set firewall.lan_to_docker.src='lan'
uci set firewall.lan_to_docker.dest='docker'

uci commit firewall
EOF
fi

# 追加自删除命令
cat << EOF >> "$INIT_SETTING"

# 运行一次后自删除，保持系统干净
rm -f /etc/uci-defaults/99-init-settings
exit 0
EOF

# 确保初始化脚本有执行权限
chmod +x "$INIT_SETTING"

# >>> 4. 软件包组合策略 <<<
# 基础常用工具
BASE_PKGS="curl wget iperf3 luci-i18n-diskman-zh-cn luci-i18n-filemanager-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server"
# 主题与 UI
THEME_PKGS="luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
# 网络插件 (UPnP, 防火墙, 定时重启)
NET_PKGS="luci-i18n-firewall-zh-cn luci-i18n-upnp-zh-cn luci-i18n-autoreboot-zh-cn"
# 科学上网
PROXY_PKGS="luci-app-openclash"

# 处理 Docker 插件需求
DOCKER_PKGS=""
if [ "$INCLUDE_DOCKER" == "yes" ]; then
    echo -e "${YELLOW}🐳 已开启 Docker 支持，正在追加相关依赖包...${NC}"
    DOCKER_PKGS="luci-app-dockerman dockerd docker-compose"
fi

# 合并所有包
PACKAGES="$BASE_PKGS $THEME_PKGS $NET_PKGS $PROXY_PKGS $DOCKER_PKGS $CUSTOM_PACKAGES"

# >>> 5. OpenClash 核心预集成 (优化版) <<<
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo -e "${YELLOW}⬇️ 正在为 OpenClash 准备核心文件...${NC}"
    CORE_PATH="files/etc/openclash/core"
    mkdir -p "$CORE_PATH"
    
    # Github Actions 在海外，不需要使用国内镜像代理，直连更稳定且速度极快
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    
    # 下载并解压，增加超时到30秒，重试3次
    if wget -q --show-progress -T 30 -t 3 -O- "$META_URL" | tar xOvz > "$CORE_PATH/clash_meta"; then
        chmod +x "$CORE_PATH/clash_meta"
        echo -e "${GREEN}✅ Meta 核心预装成功${NC}"
    else
        echo -e "${YELLOW}⚠️ 核心下载失败或超时，编译将继续，请稍后在路由后台手动更新。${NC}"
    fi
fi

# >>> 6. 执行镜像打包 <<<
echo -e "${BLUE}🛠️ 正在调用镜像构建器 (使用多核加速)...${NC}"

# 自动获取 CPU 核心数加速打包进程
make image PROFILE="generic" \
           PACKAGES="$PACKAGES" \
           FILES="files" \
           ROOTFS_PARTSIZE=${ROOTFS_SIZE:-1024} \
           -j$(nproc)

# >>> 7. 结束提示 <<<
echo "========================================================="
echo -e "🎉 [$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}固件编译成功！${NC}"
echo -e "📂 固件存放位置: ${BLUE}bin/targets/x86/64/${NC}"
echo "========================================================="
