#!/bin/bash
set -e

# 1. 自动识别架构下载 OpenClash 内核
case "$TARGET_ARCH" in
    *"x86-64"*)    CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*) CORE="arm64" ;;
    *"armv7"*)     CORE="armv7" ;;
    *"ramips"*)    CORE="mipsle-softfloat" ;;
    *"mips"*)      CORE="mips-softfloat" ;;
    *)             CORE="arm64" ;; # 默认
esac

echo ">>> 架构: $TARGET_ARCH | 选用内核: $CORE <<<"

# 2. 准备目录
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 3. 下载插件
# 下载 OpenClash APK
OC_APK=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
wget -qO files/root/luci-app-openclash.apk "$OC_APK"

# 下载对应内核
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true

# 4. 编写初始化脚本 (极其简洁)
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 设置 IP 和 主机名
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system

# 修复软件源
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true

# 安装插件
apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 5. 定义软件包 (只包含通用插件，不含 x86 网卡驱动)
PKGS="luci luci-base luci-compat luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn \
bash jq curl ca-bundle luci-app-ttyd luci-i18n-ttyd-zh-cn \
luci-app-statistics luci-i18n-statistics-zh-cn \
coreutils-nohup block-mount kmod-fs-ext4"

# 6. 执行构建
#make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
make info
