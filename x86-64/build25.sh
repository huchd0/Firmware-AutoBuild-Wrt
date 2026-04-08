#!/bin/bash
set -e 

echo "========================================================="
echo "🕒 [$(date '+%Y-%m-%d %H:%M:%S')] 开始构建流程..."
echo "📦 目标分区大小: $PROFILE MB"
echo "========================================================="

# 读取自定义包
if [ -f "shell/custom-packages.sh" ]; then
    source shell/custom-packages.sh
fi

# ================= 自动化初始化脚本 =================
echo "🔧 写入系统初始化配置 (LAN IP)..."
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

cat << EOF > /home/build/immortalwrt/files/etc/uci-defaults/99-init-settings
#!/bin/sh
uci set network.lan.ipaddr='$CUSTOM_ROUTER_IP'
uci commit network
rm -f /etc/uci-defaults/99-init-settings
exit 0
EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-init-settings

# ================= 软连接与包组合 =================
# 基础常用工具与测速
PACKAGES="curl wget iperf3 luci-i18n-diskman-zh-cn luci-i18n-filemanager-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server"
# 主题外观
PACKAGES="$PACKAGES luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
# 网络防火墙与辅助 (新增 UPnP 和 定时重启)
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn luci-i18n-upnp-zh-cn luci-i18n-autoreboot-zh-cn"
# 科学上网
PACKAGES="$PACKAGES luci-app-openclash"
# 合并自定义包
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# ================= OpenClash 核心预集成 =================
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "⬇️ 正在为 OpenClash 准备核心文件..."
    mkdir -p files/etc/openclash/core
    
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    if wget -q --show-progress -O- "$META_URL" | tar xOvz > files/etc/openclash/core/clash_meta; then
        chmod +x files/etc/openclash/core/clash_meta
        echo "✅ Meta 核心预装成功"
    else
        echo "⚠️ 核心下载失败，编译将继续，但固件内需手动更新。"
    fi
fi

# ================= 执行镜像打包 =================
echo "🛠️ 正在调用镜像构建器..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

echo "🎉 [$(date '+%Y-%m-%d %H:%M:%S')] 编译成功！"
