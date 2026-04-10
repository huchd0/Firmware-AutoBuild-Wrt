#!/bin/bash
set -e

# 1. 架构识别
case "$TARGET_ARCH" in
    *"x86-64"*)    CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*) CORE="arm64" ;;
    *"ramips"*)    CORE="mipsle-softfloat" ;;
    *)             CORE="mipsle-softfloat" ;; 
esac

echo ">>> 架构: $TARGET_ARCH | 选用内核: $CORE <<<"

# 2. 清理并准备目录
rm -rf files && mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 3. 下载插件 (增加重试逻辑)
echo ">>> 下载 OpenClash APK..."
OC_APK=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)
wget -t 3 -T 30 -qO files/root/luci-app-openclash.apk "$OC_APK" || echo "Warning: APK download failed"

# 4. 【关键修改】不要在构建时打入 Meta 内核
# 对于 16MB 的 afoundry_ew1200，把 20MB 的内核打进固件必爆！
# 建议刷好固件后，通过 OpenClash 界面手动上传内核
echo ">>> 跳过内核预装以节省空间 (16MB Flash 必须跳过) <<<"

# 5. 初始化脚本
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system
# 修正软件源
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
# 安装插件并清理
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 6. 软件包列表 (针对 16MB 设备进行极致瘦身)
# 必须去掉所有无用的驱动，否则 make 会直接报错退出
PKGS="-dnsmasq dnsmasq-full \
-kmod-usb-core -kmod-usb3 -kmod-usb-stack -kmod-usb-ohci -kmod-usb2 \
-kmod-usb-ledtrig-usbport -kmod-usb-serial -kmod-usb-serial-option -kmod-usb-net -kmod-usb-net-cdc-ncm \
-ppp -ppp-mod-pppoe \
-ip6tables -kmod-nft-bridge -kmod-nf-conntrack6 \
luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"

echo ">>> 检查 Profile: $DEVICE_PROFILE"
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
