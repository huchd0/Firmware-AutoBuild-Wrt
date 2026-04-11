#!/bin/bash
set -e

# 1. 架构识别与内核版本锁定
case "$TARGET_ARCH" in
    *"x86-64"*)    CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*) CORE="arm64" ;;
    *"mediatek-filogic"*)  CORE="arm64" ;; # AX6000 使用此架构
    *"ramips"*)    CORE="mipsle-softfloat" ;;
    *)             CORE="arm64" ;; 
esac

echo ">>> 🚀 目标架构: $TARGET_ARCH | 选用内核: $CORE <<<"

# 2. 准备目录 (安全清理)
[ -d files ] && find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 3. 下载插件与内核 (高性能设备建议全部注入)
echo ">>> 📥 正在获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

echo ">>> 📥 正在注入 OpenClash Meta 内核..."
# 红米 AX6000 空间大，直接注入内核，刷完即用
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true

# 4. 编写全自动初始化脚本
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 基础网络设置
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Redmi-AX6000'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 修复软件源为国内镜像 (中科大)
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true

# 自动安装预留的 APK 插件
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 5. 定义软件包列表 (红米 AX6000 专属满血包)
# 空间大就是任性，把好用的全装上
PKGS="-dnsmasq dnsmasq-full \
luci-app-openclash \
luci-app-ttyd \
luci-i18n-ttyd-zh-cn \
luci-app-statistics \
luci-i18n-statistics-zh-cn \
luci-theme-argon \
luci-app-argon-config \
bash jq curl htop coreutils-nohup"

# 6. 执行构建 (带自动纠错逻辑)
echo ">>> 🛠️ 检查并构建固件: $DEVICE_PROFILE ..."

# 自动纠错：如果填写的 Profile 不存在，尝试搜索包含关键字的 Profile
if ! make info | grep -q "^${DEVICE_PROFILE}:"; then
    echo "⚠️ 警告: 未找到精确匹配的 Profile '$DEVICE_PROFILE'，正在尝试智能匹配..."
    
    # 提取型号关键词，比如 ax6000
    KEYWORD=$(echo "$DEVICE_PROFILE" | grep -oE "ax[0-9]+")
    SUGGESTION=$(make info | grep -i "$KEYWORD" | head -n 1 | cut -d ':' -f 1)
    
    if [ -n "$SUGGESTION" ]; then
        echo "✅ 发现匹配项: $SUGGESTION，自动替换并继续构建。"
        DEVICE_PROFILE="$SUGGESTION"
    else
        echo "❌ 无法匹配设备，请检查 arch 是否正确。可用 Profile 列表如下："
        make info | grep ":" | head -n 20
        exit 1
    fi
fi

make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
