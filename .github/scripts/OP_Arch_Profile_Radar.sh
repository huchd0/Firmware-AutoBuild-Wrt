#!/bin/bash

echo ">>> 目标环境版本: ${VERSION}"
echo -e "=======================================================\n"

# ==========================================
# 📝 1. 净化与防呆逻辑
# ==========================================
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

RAW_ARCH=$(echo "$INPUT_ARCH" | tr '[:upper:]' '[:lower:]' | xargs)
RAW_CHIP=$(echo "$INPUT_CHIP" | tr '[:upper:]' '[:lower:]' | xargs) # 新增：芯片特征输入
RAW_BRAND=$(echo "$INPUT_BRAND" | tr '[:upper:]' '[:lower:]' | xargs)
RAW_MODEL=$(echo "$INPUT_MODEL" | tr '[:upper:]' '[:lower:]' | xargs)

if [ -z "$RAW_ARCH" ] && [ -z "$RAW_CHIP" ] && [ -z "$RAW_BRAND" ] && [ -z "$RAW_MODEL" ]; then
   echo "❌ 触发防呆拦截：架构、芯片、品牌、型号不能全部为空！请至少填写一项线索。"
   exit 1
fi

# ==========================================
# 📝 2. 多维度超强字典配置 (芯片/品牌/型号)
# ==========================================

# 🧠 芯片字典 (主流 SoC -> OpenWrt Target 架构)
CHIP_DICT="
mt7981|mt7981b|mt7981a    (mediatek-filogic)
mt7986|mt7986a|mt7986b    (mediatek-filogic)
mt7988|mt7988a|mt7988d    (mediatek-mt7988)
mt7621|mt7621a|mt7621at   (ramips-mt7621)
mt7620|mt7620a            (ramips-mt7620)
mt7622|mt7622b            (mediatek-mt7622)
mt7628|mt7628an           (ramips-mt76x8)
mt7688|mt7688an           (ramips-mt76x8)
ipq6000|ipq6018|ipq6010   (qualcomm-ipq60xx)
ipq8071|ipq8072|ipq8074   (qualcomm-ipq807x)
ipq8071a|ipq8070          (qualcomm-ipq807x)
ipq4019|ipq4029           (ipq40xx-generic)
ipq5018|ipq5000           (qualcomm-ipq50xx)
ipq8064|ipq8065           (ipq806x-generic)
qca9531|qca9533           (ath79-generic)
qca9561|qca9563           (ath79-generic)
rk3328                    (rockchip-armv8)
rk3399                    (rockchip-armv8)
rk3568|rk3566             (rockchip-armv8)
rk3588|rk3588s            (rockchip-armv8)
bcm4908|bcm4906           (bcm4908-generic)
bcm4708|bcm4709           (bcm53xx-generic)
s905x3|s905x4             (amlogic-meson)
s922x                     (amlogic-meson)
"

# 🏷️ 品牌字典 (常见叫法 -> Target Profile 品牌前缀)
BRAND_DICT="
小米|mi|xiaomi           (xiaomi)
红米|redmi               (redmi)
华硕|败家之眼|asus       (asus)
普联|tp|tplink           (tplink|tp-link)
网件|netgear             (netgear)
领势|linksys             (linksys)
腾达|tenda               (tenda)
水星|mercury             (mercury)
中兴|zte                 (zte)
华为|huawei              (huawei)
友讯|dlink               (dlink)
华三|h3c                 (h3c)
锐捷|星耀|ruijie         (ruijie)
京东云|jd|无线宝|jdcloud (jdcloud)
斐讯|phicomm             (phicomm)
新路由|newifi|dteam      (newifi|d-team)
极路由|hiwifi            (hiwifi)
奇虎|360                 (qihoo)
移动|中国移动|cmcc       (cmcc)
联通|中国联通|cucc       (cucc|unicom)
电信|中国电信|ctcc       (ctcc|telecom)
捷稀|jcg                 (jcg)
广和通|glinet|gl         (glinet)
友善|nanopi|friendlyarm  (friendlyarm)
迅雷|网心云|赚钱宝|xunlei(xunlei|onething|thunder)
竞斗云|pbr               (pbr)
创维|skyworth            (skyworth)
兆能|zn                  (zn)
贝尔|上海贝尔|nokia      (sbell|nokia)
"

# 📦 型号字典 (花名/别名/运营商型号 -> Target Profile 具体型号)
MODEL_DICT="
# --- 京东云 (JDCloud) ---
一代|1代|坐享其成|sp01b   (re-sp-01b)
鲁班|2代|二代|cp02         (re-cp-02)
亚瑟|ax1800pro|cp03       (re-cp-03)
雅典娜|ax6600             (ax6600)
百里                      (ax6000)
亚瑟pro                   (re-cp-03-pro)

# --- 小米 & 红米 (Xiaomi/Redmi) ---
ax3000t                   (ax3000t)
ax3600                    (ax3600)
ax6000                    (ax6000)
ax9000                    (ax9000)
ax5                       (ax5)
ax6                       (ax6)
ac2100|红米ac2100         (ac2100)
cr6606|cr6608|cr6609      (cr660x)
wr30u|联通wr30u           (wr30u)
r3g|路由器3g               (mi-router-3g)

# --- 斐讯 (Phicomm) ---
k2|k2经典                 (k2)
k2p|k2p神机               (k2p)
k3|k3路由器               (k3)
k3c                       (k3c)
n1|n1盒子                 (n1)

# --- 友善 (NanoPi) ---
r2s                       (nanopi-r2s)
r4s                       (nanopi-r4s)
r5s                       (nanopi-r5s)
r5c                       (nanopi-r5c)
r6s                       (nanopi-r6s)

# --- 广和通 (GL.iNet) ---
sft1200|紫米              (sft1200)
mt2500|mt2500a            (mt2500)
mt3000                    (mt3000)
ax1800|燧石               (ax1800)

# --- 经典与其他常见 ---
新路由1|y1|mini           (y1)
新路由2|d1                (d1)
新路由3|d2|newifi3        (d2)
t7|360t7                  (t7)
q20|捷稀q20               (q20)
q30|捷稀q30               (q30)
rax3000m|移动rax3000m     (rax3000m)
e8820s|中兴e8820s         (e8820s)
m1|竞斗云m1|2.0           (m1)
m2|兆能m2                 (m2)
"

# ==========================================
# ⚙️ 3. 核心翻译引擎与智能推导
# ==========================================
translate() {
  local input="$1"
  local dict="$2"
  local output=""
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
          output="$output $target"
          matched=1
          break 2
        fi
      done
    done <<< "$dict"
    if [ $matched -eq 0 ]; then output="$output $word"; fi
  done
  echo $(echo "$output" | xargs)
}

# 执行多维度翻译
PARSED_CHIP=$(translate "$RAW_CHIP" "$CHIP_DICT")
PARSED_BRAND=$(translate "$RAW_BRAND" "$BRAND_DICT")
PARSED_MODEL=$(translate "$RAW_MODEL" "$MODEL_DICT")

# 🧠 智能推导逻辑：
# 如果用户输入了芯片，成功翻译出了标准架构，且用户没有手动指定架构
# 则自动补全 RAW_ARCH，直接触发高效的 Docker 提取或精确定位
if [ -n "$PARSED_CHIP" ] && [ "$PARSED_CHIP" != "$RAW_CHIP" ] && [ -z "$RAW_ARCH" ]; then
    RAW_ARCH=$(echo "$PARSED_CHIP" | awk '{print $1}')
    echo "💡 智能推导：根据芯片 [$RAW_CHIP] 自动锁定底层架构为 [$RAW_ARCH]"
fi

QUERY_B="${PARSED_BRAND// /.*}"
QUERY_M="${PARSED_MODEL// /.*}"

echo "🔍 引擎启动状态："
[ -n "$RAW_ARCH" ] && echo "    - 扫描模式: [本地 Docker 极速穿透 / 精确检索]" || echo "    - 扫描模式: [全网多线程爬虫盲搜]"
echo "    - 架构锁定: [${RAW_ARCH:-未指定}]"
echo "    - 芯片输入: [${RAW_CHIP:-未指定}] -> 映射特征: [${PARSED_CHIP:-无}]"
echo "    - 品牌锁定: [${RAW_BRAND:-未指定}] -> 匹配关键词: [$QUERY_B]"
echo "    - 型号锁定: [${RAW_MODEL:-未指定}] -> 匹配关键词: [$QUERY_M]"
echo -e "-------------------------------------------------------\n"

# ==========================================
# 🚀 4. 底层提取
# ==========================================
ALL_LIST=""

if [ -n "$RAW_ARCH" ]; then
    echo ">>> 检测到已锁定架构，尝试 Docker 本地环境提取..."
    docker pull -q immortalwrt/imagebuilder:${RAW_ARCH}-openwrt-${VERSION} >/dev/null 2>&1 || true
    ALL_LIST=$(docker run --rm immortalwrt/imagebuilder:${RAW_ARCH}-openwrt-${VERSION} make info 2>/dev/null | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1 | awk -v arch="$RAW_ARCH" '{print arch " : " $1}')
    
    if [ -z "$ALL_LIST" ]; then
        echo "❌ 拉取失败：Docker 源暂无此镜像或架构拼写错误。"
        # 降级稳定版 Fallback 的判定交由上层 YAML 处理
    fi
else
    echo ">>> 正在深入镜像节点抓取架构池..."
    MIRROR_BASE="https://mirrors.ustc.edu.cn/immortalwrt/releases/${VERSION}/targets"
    OFFICIAL_BASE="https://downloads.immortalwrt.org/releases/${VERSION}/targets"
    
    TARGETS=$(curl -sL --max-time 10 "${MIRROR_BASE}/" 2>/dev/null | grep -oE 'href="[^"]+/"' | cut -d'"' -f2 | grep -vE "^(\.\.|/|http)" | sed 's/\///g')
    [ -z "$TARGETS" ] && TARGETS=$(curl -sL --max-time 10 "${OFFICIAL_BASE}/" 2>/dev/null | grep -oE 'href="[^"]+/"' | cut -d'"' -f2 | grep -vE "^(\.\.|/|http)" | sed 's/\///g')
    
    if [ -n "$TARGETS" ]; then
        cat << 'EOF' > /tmp/get_sub.sh
#!/bin/bash
t="$1"
ver="$2"
mir="https://mirrors.ustc.edu.cn/immortalwrt/releases/${ver}/targets"
off="https://downloads.immortalwrt.org/releases/${ver}/targets"
res=$(curl -sL --max-time 10 "${mir}/${t}/" 2>/dev/null | grep -oE 'href="[^"]+/"' | cut -d'"' -f2 | grep -vE "^(\.\.|/|http)" | sed 's/\///g' | sed "s/^/$t-/")
[ -z "$res" ] && res=$(curl -sL --max-time 10 "${off}/${t}/" 2>/dev/null | grep -oE 'href="[^"]+/"' | cut -d'"' -f2 | grep -vE "^(\.\.|/|http)" | sed 's/\///g' | sed "s/^/$t-/")
echo "$res"
EOF
        chmod +x /tmp/get_sub.sh
        
        ARCH_LIST=$(printf "%s\n" "$TARGETS" | xargs -I {} -P 8 /tmp/get_sub.sh "{}" "$VERSION" | grep -v "^$")
        echo ">>> 锁定 $(echo "$ARCH_LIST" | wc -w) 个独立子架构。正在启动高并发特征提取..."
        
        mkdir -p /tmp/profiles
        cat << 'EOF' > /tmp/fetch_json.sh
#!/bin/bash
arch="$1"
ver="$2"
subpath=$(echo "$arch" | tr "-" "/")
URL="https://mirrors.ustc.edu.cn/immortalwrt/releases/${ver}/targets/${subpath}/profiles.json"
FALLBACK="https://downloads.immortalwrt.org/releases/${ver}/targets/${subpath}/profiles.json"

if ! curl -sL -f --connect-timeout 5 --max-time 15 -o "/tmp/profiles/${arch}_raw.json" "$URL" 2>/dev/null; then
    curl -sL -f --connect-timeout 5 --max-time 15 -o "/tmp/profiles/${arch}_raw.json" "$FALLBACK" 2>/dev/null || true
fi

if [ -s "/tmp/profiles/${arch}_raw.json" ] && jq -e . "/tmp/profiles/${arch}_raw.json" >/dev/null 2>&1; then
    jq -r '.profiles | keys[]' "/tmp/profiles/${arch}_raw.json" | awk -v a="$arch" '{print a " : " $1}' > "/tmp/profiles/${arch}.txt"
fi
EOF
        chmod +x /tmp/fetch_json.sh
        
        printf "%s\n" "$ARCH_LIST" | xargs -I {} -P 10 /tmp/fetch_json.sh "{}" "$VERSION"
        cat /tmp/profiles/*.txt > /tmp/all_list.txt 2>/dev/null || true
        ALL_LIST=$(cat /tmp/all_list.txt 2>/dev/null || true)
        
        echo ">>> ✅ 数据重组完毕！共挖掘到 $(echo "$ALL_LIST" | wc -l) 款设备。"
    fi
fi

# ==========================================
# 🎯 5. 过滤与智能降维输出
# ==========================================
RESULT=$(echo "$ALL_LIST" | grep -iE "$QUERY_B" | grep -iE "$QUERY_M" || true)

if [ -z "$RESULT" ]; then
    PURE_NUM=$(echo "$RAW_MODEL" | tr -cd '0-9')
    if [ -n "$PURE_NUM" ] && [ ${#PURE_NUM} -gt 1 ]; then
        RESULT=$(echo "$ALL_LIST" | grep -iE "$QUERY_B" | grep -iE "$PURE_NUM" || true)
        [ -z "$RESULT" ] && [ -z "$RAW_BRAND" ] && RESULT=$(echo "$ALL_LIST" | grep -iE "$PURE_NUM" || true)
    fi
fi

if [ -z "$RESULT" ]; then
  echo "❌ 匹配失败：数据库中未找到符合条件的设备。"
  
  if ! grep -q "❌ 匹配失败" $GITHUB_STEP_SUMMARY 2>/dev/null; then
    {
      echo "### ❌ 匹配失败"
      echo "在版本 \`${VERSION}\` 中未找到包含 \`${RAW_BRAND} ${RAW_CHIP} ${RAW_MODEL}\` 的设备。"
    } >> $GITHUB_STEP_SUMMARY
  fi
else
  echo "✅ 匹配成功！为您精准锁定以下组合："
  echo -e "======================================================="
  FORMATTED_RESULT=$(echo "$RESULT" | awk -F ' : ' '{printf "%-18s:%s\n", $1, $2}' | sort -u)
  echo "$FORMATTED_RESULT"
  echo -e "======================================================="
  
  {
    echo "### ✅ 匹配成功！(\`${VERSION}\`)"
    echo '```text'
    echo "$FORMATTED_RESULT"
    echo '```'
  } >> $GITHUB_STEP_SUMMARY
fi
