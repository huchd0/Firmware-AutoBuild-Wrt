#!/bin/bash
set -e
set -o pipefail

# ==========================================
# 📝 1. 品牌容错字典与净化逻辑
# ==========================================
BRAND_DICT="
小米|mi                (xiaomi)
红米                  (redmi)
华硕|败家之眼|asus     (asus)
普联|tp|tplink         (tplink|tp-link)
网件|netgear           (netgear)
领势|linksys           (linksys)
腾达|tenda             (tenda)
水星|mercury           (mercury)
中兴|zte               (zte)
华为|huawei            (huawei)
华三|h3c               (h3c)
锐捷|ruijie            (ruijie)
京东云|jd|无线宝       (jdcloud)
斐讯|phicomm           (phicomm)
新路由|newifi|dteam    (newifi|d-team)
极路由|hiwifi          (hiwifi)
奇虎|360               (qihoo)
移动|中国移动|cmcc     (cmcc)
友善|nanopi|friendlyarm (friendlyarm)
"

# 再次净化并转换品牌输入为小写
RAW_BRAND=$(echo "$BRAND_INPUT" | xargs | tr '[:upper:]' '[:lower:]')
# Profile 仅去除左右空格，保留原样交由 grep -ix 匹配
EXACT_PROFILE=$(echo "$DEVICE_PROFILE" | xargs)

translate_brand() {
  local input="$1"
  local dict="$2"
  [ -z "$input" ] && return
  for word in $input; do
    local matched=0
    while IFS= read -r line; do
      [[ ! "$line" =~ [^[:space:]] ]] && continue
      local target=$(echo "${line##*\(}" | tr -d ')')
      local aliases_str=$(echo "${line%\(*}" | tr '[:upper:]' '[:lower:]')
      IFS='|' read -ra ALIAS_ARRAY <<< "$aliases_str"
      for raw_alias in "${ALIAS_ARRAY[@]}"; do
        local clean_alias=$(echo "$raw_alias" | xargs)
        if [[ "$word" == "$clean_alias" ]]; then
          echo "$target"
          return
        fi
      done
    done <<< "$dict"
    if [ $matched -eq 0 ]; then echo "$word"; fi
  done
}

BRAND_KEYWORD=$(translate_brand "$RAW_BRAND" "$BRAND_DICT" | tr ' ' '|')

# ==========================================
# ⚙️ 2. 架构内核精准适配
# ==========================================
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac
echo ">>> 🌍 架构识别: $TARGET_ARCH | 内核适配: $CORE"

# ==========================================
# 📁 3. 目录初始化
# ==========================================
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# ==========================================
# 📥 4. 插件与内核获取
# ==========================================
echo ">>> 📥 获取 OpenClash APK..."
OC_URL=$(curl -sL https://api.github.com/repos/vernesong/OpenClash/releases/latest | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)

if [[ "$OC_URL" != http* ]]; then
    echo "❌ 致命错误: GitHub API 限流。为防刷砖，构建中止。"
    exit 1
fi
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

if [[ "$TARGET_ARCH" == *"ramips"* ]] || [[ "$TARGET_ARCH" == *"ath79"* ]]; then
    echo "⚠️ 预警：检测到小容量架构，跳过 Meta 内核注入以防固件过大变砖。"
else
    echo ">>> 📥 注入 Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# ==========================================
# 🔧 5. 静默配置脚本
# ==========================================
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# 📦 6. 软件包精简策略
# ==========================================
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    PKGS="$PKGS -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3"
fi

# ==========================================
# 🛡️ 7. 【铁腕防爆】无视大小写的精准全字匹配
# ==========================================
echo ">>> 🛠️ 安全校验：严格 Profile 匹配与品牌双保险..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)

# 【第一关：无视大小写的精准全字匹配】
# grep -ix: -i 忽略大小写, -x 匹配整行 (不能多一个字母也不能少一个字母)
FINAL_PROFILE=$(echo "$ALL_PROFILES" | grep -ix "$EXACT_PROFILE" || true)
MATCH_COUNT=$(echo "$FINAL_PROFILE" | grep -v '^$' | wc -l || echo 0)

if [ "$MATCH_COUNT" -eq 1 ]; then
    # 取出官方原本的标准大小写代号
    FINAL_PROFILE=$(echo "$FINAL_PROFILE" | tr -d '[:space:]')
    echo "✅ 第一重校验通过：成功锁定并修正标准底层代号 -> $FINAL_PROFILE"
elif [ "$MATCH_COUNT" -gt 1 ]; then
    echo "❌ 严重错误：数据库中存在重名代号异常，触发安全锁死机制。"
    exit 1
else
    echo "❌ 致命错误：当前架构下不存在该设备代号！"
    echo "您输入的是: [$EXACT_PROFILE]"
    echo "请先使用 【OP Arch & Profile Radar】 查询出完全正确的 Profile 代号后再来编译。"
    exit 1
fi

# 【第二关：品牌双保险】
if [ -n "$BRAND_KEYWORD" ]; then
    if echo "$FINAL_PROFILE" | grep -iqE "$BRAND_KEYWORD"; then
        echo "✅ 第二重校验通过：您输入的品牌匹配无误！"
    else
        echo "❌ 刷砖预警：您输入的品牌 [$BRAND_INPUT] 与设备代号 [$FINAL_PROFILE] 不匹配！"
        echo "为防止选错机器刷成砖头，编译强制中止。"
        exit 1
    fi
else
    echo "⚠️ 未填写品牌，跳过品牌双保险校验..."
fi

# ==========================================
# 🚀 8. 终极打包与加注架构名
# ==========================================
echo ">>> 🚀 安全护航完毕，正在为您全速打包固件..."
make image PROFILE="$FINAL_PROFILE" PACKAGES="$PKGS" FILES="files"

echo ">>> 🏷️ 正在为生成的固件注入架构标识..."
cd bin/targets/*/* || true

for img in *.{bin,img.gz}; do
    if [ -f "$img" ]; then
        base="${img%.*}"
        ext="${img##*.}"
        if [[ "$img" == *.img.gz ]]; then
            base="${img%.img.gz}"
            ext="img.gz"
        fi
        new_name="${base}-${TARGET_ARCH}.${ext}"
        echo "✅ 成功重命名并加注架构: $new_name"
        mv "$img" "$new_name"
    fi
done
