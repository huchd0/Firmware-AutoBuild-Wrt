#!/bin/bash
set -e
set -o pipefail

# --- 1. 架构识别 ---
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *"mips"*)               CORE="mips-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac

echo ">>> 🌍 架构: $TARGET_ARCH | 内核: $CORE"

# --- 2. 目录清理 ---
[ -d files ] && find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# --- 3. 插件下载与安全校验 ---
echo ">>> 📥 获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

if [[ "$OC_URL" != http* ]]; then
    echo "❌ 错误: 无法获取合法的下载链接，构建中止。"
    exit 1
fi
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# --- 4. 空间策略 ---
if [[ "$TARGET_ARCH" == *"ramips"* ]] || [[ "$TARGET_ARCH" == *"ath79"* ]]; then
    echo "⚠️ 乞丐版架构，不注入内核。"
else
    echo ">>> 📥 注入 OpenClash Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# --- 5. 初始化脚本 ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- 6. 软件包列表 ---
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"
if [[ "$TARGET_ARCH" == *"ramips"* ]] || [[ "$TARGET_ARCH" == *"ath79"* ]]; then
    PKGS="$PKGS -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3"
fi

# --- 7. 【核心优化】品牌+型号 双重锁定匹配逻辑 ---
echo ">>> 🛠️ 开始安全校验 Profile..."

# 如果用户直接输入了完美的 ID (如 xiaomi_redmi-router-ax6000-stock)
if make info | grep -q "^${DEVICE_PROFILE}:"; then
    echo "✅ 精确匹配成功: $DEVICE_PROFILE"
else
    echo "⚠️ 未找到精确匹配，执行品牌[$BRAND] + 型号[$DEVICE_PROFILE] 组合过滤..."
    
    # 核心算法：同时匹配品牌关键字和型号关键字
    # 排除掉常见的特殊字符，只搜索 ID 部分
    MATCH_LIST=$(make info | grep "^[a-zA-Z0-9_-]*:" | grep -i "$BRAND" | grep -i "$DEVICE_PROFILE" | cut -d ':' -f 1)
    MATCH_COUNT=$(echo "$MATCH_LIST" | grep -v '^$' | wc -l)

    if [ "$MATCH_COUNT" -eq 1 ]; then
        DEVICE_PROFILE=$(echo "$MATCH_LIST" | tr -d '[:space:]')
        echo "✅ 唯一匹配成功: $DEVICE_PROFILE"
    elif [ "$MATCH_COUNT" -gt 1 ]; then
        echo "❌ 风险预警: 在品牌[$BRAND]下发现多个匹配型号:"
        echo "$MATCH_LIST"
        echo "请在界面填写更具体的型号名，构建中止。"
        exit 1
    else
        echo "❌ 匹配失败: 在品牌[$BRAND]中找不到包含[$DEVICE_PROFILE]的设备。"
        echo "提示：如果不确定品牌，请尝试清空品牌输入框或检查 arch 是否选对。"
        exit 1
    fi
fi

# --- 8. 执行构建 ---
echo ">>> 🚀 安全校验通过，开始打包固件..."
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
