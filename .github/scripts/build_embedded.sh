#!/bin/bash
# 注意：取消 set -e，以便在 ImageBuilder 报虚假错误时，脚本能继续执行抢救逻辑
set -o pipefail

# ==========================================
# 📝 1. 品牌容错字典 (芯片推导已交由 YAML 前端预处理)
# ==========================================
BRAND_DICT="
小米|mi                (xiaomi)
红米                   (redmi)
华硕|败家之眼|asus       (asus)
普联|tp|tplink         (tplink|tp-link)
网件|netgear           (netgear)
领势|linksys           (linksys)
腾达|tenda             (tenda)
水星|mercury           (mercury)
中兴|zte               (zte)
华为|huawei            (huawei)
华三|h3c               (h3c)
锐捷|ruijie            (ruijie)
京东云|jd|无线宝        (jdcloud)
斐讯|phicomm           (phicomm)
新路由|newifi|dteam    (newifi|d-team)
极路由|hiwifi          (hiwifi)
奇虎|360               (qihoo)
移动|中国移动|cmcc      (cmcc)
友善|nanopi|friendlyarm(friendlyarm)
"

RAW_BRAND=$(echo "$BRAND_INPUT" | xargs | tr '[:upper:]' '[:lower:]')
EXACT_PROFILE=$(echo "$DEVICE_PROFILE" | xargs)

translate_brand() {
  local input="$1"; local dict="$2"
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
        if [[ "$word" == "$clean_alias" ]]; then echo "$target"; return; fi
      done
    done <<< "$dict"
  done
  echo "$input"
}
BRAND_KEYWORD=$(translate_brand "$RAW_BRAND" "$BRAND_DICT" | tr ' ' '|')

# ==========================================
# ⚙️ 2. 架构内核适配 (接收 YAML 传来的标准架构)
# ==========================================
echo ">>> 接收到标准底层架构: $TARGET_ARCH"

case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac

# ==========================================
# 📁 3. 目录初始化
# ==========================================
mkdir -p files/etc/uci-defaults files/etc/openclash/core

# ==========================================
# 📦 4. 模式化分流：软件包策略与 Extroot 脚本
# ==========================================
# 基础包列表
PKGS="-dnsmasq dnsmasq-full luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    echo ">>> 🗑️ [丐版模式] 强行剔除所有组件..."
    PKGS="$PKGS -luci-app-openclash -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3 -kmod-usb2"

elif [ "$BUILD_MODE" == "Extroot" ]; then
    echo ">>> 💾 [扩容模式] 注入 USB 驱动，配置容错与全自动装机逻辑..."
    # ✅ 固件本底保留了 wpad (无线) 和 ppp (拨号)，仅剔除最大的 OpenClash
    PKGS="$PKGS block-mount e2fsprogs kmod-fs-ext4 kmod-usb-core kmod-usb3 kmod-usb-storage fdisk"
    PKGS="$PKGS -luci-app-openclash"
    
    # 💥 全自动扩容与后台装机脚本 (注入到路由器开机任务)
    cat << 'EOF' > files/etc/uci-defaults/90-auto-extroot
#!/bin/sh

# 1. 容错校验：判断当前的系统根目录 (/overlay) 是否挂载在 U 盘上
if df /overlay | grep -q "/dev/sd"; then
    # 系统已经在 U 盘运行！检查是否安装过 OpenClash
    if [ ! -f /usr/bin/openclash ]; then
        logger -t Extroot "✅ 检测到系统已成功运行在 U 盘，启动后台插件补全程序..."
        
        # 开启后台子进程进行下载，防止阻塞路由器的正常开机过程
        (
            # 循环检测网络连通性 (最多等待约 3 分钟，等待拨号成功)
            for i in $(seq 1 36); do
                if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then
                    logger -t Extroot "🌐 网络已连接！开始下载安装 Argon, UPnP, AutoReboot, Curl 及 OpenClash..."
                    opkg update
                    # 批量安装 U 盘必备全家桶
                    opkg install luci-theme-argon luci-app-argon-config luci-app-upnp luci-app-autoreboot curl luci-app-openclash
                    
                    # 自动识别架构并注入 Meta 内核
                    CORE_ARCH=$(uname -m)
                    case "$CORE_ARCH" in
                        x86_64) ARCH="amd64" ;;
                        mips*) ARCH="mipsle-softfloat" ;;
                        aarch64) ARCH="arm64" ;;
                        *) ARCH="arm64" ;;
                    esac
                    
                    mkdir -p /etc/openclash/core
                    curl -skL "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${ARCH}.tar.gz" | tar -zxf - -C /etc/openclash/core/
                    mv /etc/openclash/core/clash /etc/openclash/core/clash_meta 2>/dev/null
                    chmod +x /etc/openclash/core/clash_meta
                    
                    logger -t Extroot "🎉 U 盘环境插件全家桶自动部署完成！建议刷新后台页面。"
                    break
                fi
                sleep 5
            done
        ) &
    fi
    # 既然在 U 盘跑了，脚本使命完成，退出 0 让系统自我销毁此脚本
    exit 0
fi

# 2. 扩容检测：如果在内置 16MB 运行，寻找是否有 U 盘插入
sleep 15
DEVICE=$(block info | grep -oE "/dev/sd[a-z][0-9]+" | head -n 1)

if [ -n "$DEVICE" ]; then
    logger -t Extroot "💾 检测到 U 盘 $DEVICE，开始格式化并执行系统数据迁移..."
    mkfs.ext4 -F -L "extroot" "$DEVICE"
    mkdir -p /mnt/extroot && mount "$DEVICE" /mnt/extroot
    tar -C /overlay -cvf - . | tar -C /mnt/extroot -xf -
    block detect > /etc/config/fstab
    uci set fstab.@mount[0].target='/overlay'
    uci set fstab.@mount[0].enabled='1'
    uci commit fstab && sync && reboot
else
    # 容错降级：没插 U 盘
    logger -t Extroot "⚠️ 未检测到 U 盘，当前运行于内置极简容错模式。若需扩容安装全家桶，请插上 U 盘后重启路由器。"
    # 退出 1！让系统保留此脚本，下次开机还会检测！
    exit 1
fi
EOF
    chmod +x files/etc/uci-defaults/90-auto-extroot

else
    echo ">>> 🔌 [豪华模式] 注入全套组件..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    PKGS="$PKGS luci-app-openclash luci-theme-argon block-mount e2fsprogs kmod-fs-ext4 kmod-usb-core kmod-usb3 kmod-usb-storage"
fi

# ==========================================
# 🔧 5. 系统基础配置
# ==========================================
cat << EOF > files/etc/uci-defaults/99-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci commit network
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
rm -f /etc/uci-defaults/99-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-setup

# ==========================================
# 🛡️ 6. 安全校验逻辑
# ==========================================
ALL_PROFS=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)
FINAL_PROF=$(echo "$ALL_PROFS" | grep -ix "$EXACT_PROFILE" | head -n 1 || echo "$EXACT_PROFILE")

# ==========================================
# 🚀 7. 终极打包与日志监听
# ==========================================
echo ">>> 🚀 正在打包固件 (模式: $BUILD_MODE)..."

# 执行编译，同时将终端日志克隆一份保存到 build.log 中，方便我们抓包
make image PROFILE="$FINAL_PROF" PACKAGES="$PKGS" FILES="files" 2>&1 | tee build.log

# ==========================================
# 🛡️ 8. 智能排错与状态输出
# ==========================================
SUMMARY_FILE="bin/step_summary.md"

# 🔍 抓包判定 1：直接从日志里捕捉“体积超标”的死亡宣告
if grep -q "is too big" build.log; then
    echo "❌ 致命拦截：系统日志显示固件体积严重超标，ImageBuilder 拒绝打包！"
    
    {
        echo "### ❌ 编译终止：固件体积严重超标！"
        echo "> **系统拦截**: 您强行塞入了过多的插件，总容量已突破该路由器物理闪存的极限，引擎已拒绝打包。"
        echo ""
        echo "#### 💡 诊断与排错建议："
        echo "因为您选择了 \`${BUILD_MODE}\` 模式，巨大的 OpenClash 内核导致空间溢出。"
        echo "请返回重新点击 **Run workflow**，并在弹出的菜单中修改配置："
        echo ""
        echo "1. 💽 **切换为 Extroot (智能U盘扩容) 模式** 👉 **【墙裂推荐】**"
        echo "   *此模式生成的固件极小，包过！刷入后在路由器上插个闲置 U 盘，系统会自动把它变成你的无底洞内置空间，并自动联网装好全套豪华插件！*"
        echo "2. 🗑️ **切换为 Lite (丐版) 模式**"
        echo "   *不插 U 盘的妥协方案，直接剔除所有大型占用的科学插件，当普通路由器用。*"
    } >> "$SUMMARY_FILE"
    
    exit 1
fi

# 🔍 抓包判定 2：如果没有超标，正常去寻找固件并测算大小
FIRMWARE_FILE=$(find bin/targets -name "*.bin" | head -n 1)

if [ -f "$FIRMWARE_FILE" ]; then
    FILE_SIZE=$(du -k "$FIRMWARE_FILE" | cut -f1)
    echo ">>> 📊 固件检测成功！当前体积: ${FILE_SIZE}KB"
    
    {
        echo "### ✅ 编译打包成功！"
        echo "- 固件体积：**${FILE_SIZE} KB** (健康)"
        echo "- 请在页面底部的 Artifacts 中下载您的专属固件。"
    } >> "$SUMMARY_FILE"
    
else
    # 🔍 抓包判定 3：既不是太大，也没找到文件，说明是奇葩依赖冲突报错
    echo "❌ 错误：未能在 bin 目录找到生成的固件。"
    
    {
        echo "### ❌ 编译失败：未知核心报错"
        echo "ImageBuilder 引擎未能生成 bin 文件，且排除了体积超标原因。可能存在插件冲突或底层依赖缺失。"
        echo "请点开上方的 \`🏗️ 执行 Docker 构建引擎\` 步骤查看详细的红色报错日志。"
    } >> "$SUMMARY_FILE"
    
    exit 1
fi

# ==========================================
# 🏷️ 9. 重命名与清理
# ==========================================
[ -d "bin/targets/salvaged" ] && cd bin/targets/salvaged || cd bin/targets/*/* 2>/dev/null || true
for img in *.bin; do
    if [ -f "$img" ]; then
        # 在原有固件名和架构名的基础上，追加当前编译模式 (Deluxe/Extroot/Lite)
        mv "$img" "${img%.*}-${TARGET_ARCH}-${BUILD_MODE}.bin"
    fi
done
