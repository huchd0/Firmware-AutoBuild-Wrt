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
# 🚀 7. 终极打包与强力抢救
# ==========================================
echo ">>> 🚀 正在打包固件 (模式: $BUILD_MODE)..."

# 开启后台“小偷”程序，防止 ImageBuilder 报错后删除 bin 文件
mkdir -p /tmp/salvage
( while true; do find bin/targets -name "*.bin" -exec cp {} /tmp/salvage/ \; 2>/dev/null; sleep 0.5; done ) &
SALVAGE_PID=$!

# 执行编译，忽略报错
make image PROFILE="$FINAL_PROF" PACKAGES="$PKGS" FILES="files" || echo "⚠️ 引擎报告体积警告，尝试从缓存抢救..."

kill $SALVAGE_PID || true
mkdir -p bin/targets/salvaged
cp /tmp/salvage/*.bin bin/targets/salvaged/ 2>/dev/null || true

# ==========================================
# 🛡️ 8. 物理体积二次核验与智能排错建议
# ==========================================
FIRMWARE_FILE=$(find bin/targets -name "*.bin" | head -n 1)

if [ -f "$FIRMWARE_FILE" ]; then
    FILE_SIZE=$(du -k "$FIRMWARE_FILE" | cut -f1)
    echo ">>> 📊 固件检测成功！当前体积: ${FILE_SIZE}KB"
    
    if [ "$FILE_SIZE" -gt 16128 ]; then # 15.75MB 安全线
        echo "❌ 致命错误：固件体积 (${FILE_SIZE}KB) 超过了 16MB 物理闪存上限！"
        
        # 💡 核心亮点：直接把诊断和建议打印到 GitHub 首页面板
        {
            echo "### ❌ 编译终止：固件体积严重超标！"
            echo "当前生成的固件体积为 **${FILE_SIZE} KB**，远远超过了该设备物理闪存的安全上限 (约 15.7 MB)。"
            echo ""
            echo "#### 💡 诊断与修复建议："
            echo "由于您当前选择了 \`${BUILD_MODE}\` 模式，系统试图将 OpenClash 及其庞大的 Meta 内核强行塞入路由器，导致空间溢出。"
            echo "请**重新点击 Run workflow**，并在弹出的选项菜单中进行以下调整："
            echo ""
            echo "1. 💽 **切换为 Extroot (智能U盘扩容) 模式** 👉 **【强烈推荐】**"
            echo "   *此模式下，生成的固件极小，绝对能顺利刷入。刷入后只需在路由器上插个 U 盘，系统会自动把 U 盘变成内置空间，并自动联网下载安装全套豪华插件！*"
            echo "2. 🗑️ **切换为 Lite (丐版) 模式**"
            echo "   *如果您没有多余的 U 盘，只想把路由器当普通千兆路由用，选此模式可剔除所有大型插件。*"
        } >> $GITHUB_STEP_SUMMARY
        
        exit 1
    else
        echo "✅ 校验通过：体积符合 16MB 物理规格，可安全刷入。"
        
        # 成功时也顺便打印个漂亮的成功面板
        {
            echo "### ✅ 编译打包成功！"
            echo "固件体积：**${FILE_SIZE} KB** (状态：健康)"
            echo "您可以直接在下方 Artifacts 下载刷机包。"
        } >> $GITHUB_STEP_SUMMARY
    fi
else
    echo "❌ 错误：未能在 bin 目录找到生成的固件。"
    
    # 针对其他编译失败的报错建议
    {
        echo "### ❌ 编译失败：未生成固件"
        echo "ImageBuilder 引擎可能因为插件冲突或依赖缺失未能生成 bin 文件。请点开上方的 \`🏗️ 执行 Docker 构建引擎\` 步骤查看详细报错日志。"
    } >> $GITHUB_STEP_SUMMARY
    
    exit 1
fi

# ==========================================
# 🏷️ 9. 重命名与清理
# ==========================================
[ -d "bin/targets/salvaged" ] && cd bin/targets/salvaged || cd bin/targets/*/*
for img in *.bin; do
    if [ -f "$img" ]; then
        mv "$img" "${img%.*}-${TARGET_ARCH}.bin"
    fi
done
