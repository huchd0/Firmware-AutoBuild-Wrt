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

# 全流程归一化：将输入强制转为小写，实现不分大小写匹配
RAW_ARCH=$(echo "$INPUT_ARCH" | tr '[:upper:]' '[:lower:]' | xargs)
RAW_BRAND=$(echo "$INPUT_BRAND" | tr '[:upper:]' '[:lower:]' | xargs)
RAW_MODEL=$(echo "$INPUT_MODEL" | tr '[:upper:]' '[:lower:]' | xargs)

if [ -z "$RAW_ARCH" ] && [ -z "$RAW_BRAND" ] && [ -z "$RAW_MODEL" ]; then
   echo "❌ 触发防呆拦截：架构、品牌、型号不能全部为空！请至少填写一项线索。"
   exit 1
fi

# ==========================================
# 📝 2. 双字典配置 (已修正京东云底层合并关系)
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
友讯|dlink             (dlink)
华三|h3c               (h3c)
锐捷|ruijie            (ruijie)
京东云|jd|无线宝       (jdcloud)
斐讯|phicomm           (phicomm)
新路由|newifi|dteam    (newifi|d-team)
极路由|hiwifi          (hiwifi)
奇虎|360               (qihoo)
移动|中国移动|cmcc     (cmcc)
捷稀|jcg               (jcg)
广和通|glinet|gl       (glinet)
友善|nanopi|friendlyarm (friendlyarm)
迅雷|网心云|赚钱宝     (xunlei|onething|thunder)
"

MODEL_DICT="
一代|1代|坐享其成|sp01b (re-sp-01b)
鲁班|2代|二代|cp02       (re-cp-02)
亚瑟|ax1800pro|cp03     (re-cp-03)
雅典娜|ax6600           (ax6600)
百里                    (ax6000)
k2|k2经典               (k2)
k2p|k2p神机             (k2p)
k3|k3路由器             (k3)
k3c                     (k3c)
cr6606|cr6608|cr6609    (cr660x)
wr30u|联通wr30u         (wr30u)
ax3000t                 (ax3000t)
ax3600                  (ax3600)
ax9000                  (ax9000)
新路由1|y1|mini         (y1)
新路由2|d1              (d1)
新路由3|d2|newifi3      (d2)
r2s                     (nanopi-r2s)
r4s                     (nanopi-r4s)
r5s                     (nanopi-r5s)
r5c                     (nanopi-r5c)
r6s                     (nanopi-r6s)
t7|360t7                (t7)
q20|捷稀q20             (q20)
rax3000m|移动rax3000m   (rax3000m)
e8820s|中兴e8820s       (e8820s)
"

# ==========================================
# ⚙️ 3. 核心翻译引擎 (增强型：不分大小写)
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
      # 提取括号内的目标代号
      local target=$(echo "${line##*\(}" | tr -d ')')
      # 提取别名部分并转为小写
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

PARSED_BRAND=$(translate "$RAW_BRAND" "$BRAND_DICT")
PARSED_MODEL=$(translate "$RAW_MODEL" "$MODEL_DICT")

# 转换为正则表达式格式
QUERY_B="${PARSED_BRAND// /.*}"
QUERY_M="${PARSED_MODEL// /.*}"

echo "🔍 引擎启动状态："
[ -n "$RAW_ARCH" ] && echo "    - 扫描模式: [本地极速穿透 - 指定架构 $RAW_ARCH]" || echo "    - 扫描模式: [全网多线程爬虫 - 全网盲搜]"
echo "    - 品牌锁定: [${RAW_BRAND:-未指定}] -> 匹配关键词: [$QUERY_B]"
echo "    - 型号锁定: [${RAW_MODEL:-未指定}] -> 匹配关键词: [$QUERY_M]"
echo -e "-------------------------------------------------------\n"

# ==========================================
# 🚀 4. 底层提取
# ==========================================
ALL_LIST=""

if [ -n "$RAW_ARCH" ]; then
    echo ">>> 检测到已填写架构，切换至 Docker 本地环境提取..."
    docker pull -q immortalwrt/imagebuilder:${RAW_ARCH}-openwrt-${VERSION} >/dev/null 2>&1 || true
    ALL_LIST=$(docker run --rm immortalwrt/imagebuilder:${RAW_ARCH}-openwrt-${VERSION} make info 2>/dev/null | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1 | awk -v arch="$RAW_ARCH" '{print arch " : " $1}')
    
    if [ -z "$ALL_LIST" ]; then
        echo "❌ 拉取失败：该架构可能拼写错误或不存在。"
        exit 1
    fi
else
    echo ">>> 正在剥离前端外壳，深入镜像节点抓取架构池..."
    
    MIRROR_BASE="https://mirrors.ustc.edu.cn/immortalwrt/releases/${VERSION}/targets"
    OFFICIAL_BASE="https://downloads.immortalwrt.org/releases/${VERSION}/targets"
    
    # 🌟 终极优化 1：无视 HTML 差异的暴力提取正则，绝不漏抓任何目录
    TARGETS=$(curl -sL --max-time 10 "${MIRROR_BASE}/" 2>/dev/null | grep -oE 'href="[^"]+/"' | cut -d'"' -f2 | grep -vE "^(\.\.|/|http)" | sed 's/\///g')
    [ -z "$TARGETS" ] && TARGETS=$(curl -sL --max-time 10 "${OFFICIAL_BASE}/" 2>/dev/null | grep -oE 'href="[^"]+/"' | cut -d'"' -f2 | grep -vE "^(\.\.|/|http)" | sed 's/\///g')
    
    if [ -z "$TARGETS" ]; then
        echo "❌ 第一级目录抓取失败，请确认版本号 ($VERSION) 是否在服务器上真实存在。"
        exit 1
    fi
    
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
    
    echo ">>> 成功突破迷雾，锁定 $(echo "$ARCH_LIST" | wc -w) 个独立子架构！"
    
    # 🌟 终极优化 2：开启天眼，打印到底抓到了哪些架构
    echo ">>> 🐛 [Debug 诊断] 当前抓取到的架构清单："
    echo "$ARCH_LIST" | tr '\n' ' '
    echo -e "\n"
    
    echo ">>> 🚦 正在启动【高稳定性下载通道】提取海量设备特征..."
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
    
    if [ -z "$ALL_LIST" ]; then
        echo "❌ 致命错误：数据库抓取归零。"
        exit 1
    fi
    
    echo ">>> ✅ 全网数据矩阵重组完毕！总计挖掘到 $(echo "$ALL_LIST" | wc -l) 款专属设备。"
fi

# ==========================================
# 🎯 5. 增强型双重交叉过滤与智能降维输出
# ==========================================

# 1. 尝试第一轮：基于翻译后的关键词精准匹配
RESULT=$(echo "$ALL_LIST" | grep -iE "$QUERY_B" | grep -iE "$QUERY_M" || true)

# 2. 智能降维逻辑：如果第一轮落空，且型号中包含数字 (如 AX6000 -> 6000)
if [ -z "$RESULT" ]; then
    PURE_NUM=$(echo "$RAW_MODEL" | tr -cd '0-9')
    if [ -n "$PURE_NUM" ] && [ ${#PURE_NUM} -gt 1 ]; then
        echo "⚠️ 第一轮精准匹配未命中，启动 [数字降维模糊搜索]..."
        # 降维逻辑：匹配品牌关键词 且 匹配型号中的纯数字
        RESULT=$(echo "$ALL_LIST" | grep -iE "$QUERY_B" | grep -iE "$PURE_NUM" || true)
        
        # 兜底：如果还是没有，直接全库搜数字 (仅限品牌也为空时)
        if [ -z "$RESULT" ] && [ -z "$RAW_BRAND" ]; then
            RESULT=$(echo "$ALL_LIST" | grep -iE "$PURE_NUM" || true)
        fi
    fi
fi

# 3. 处理最终结果
if [ -z "$RESULT" ]; then
  echo "❌ 匹配失败：数据库中未找到符合条件的设备。"
  
  # GitHub 首页摘要反馈
  {
    echo "### ❌ 匹配失败"
    echo "在版本 \`${VERSION}\` 中未找到包含 \`${RAW_BRAND} ${RAW_MODEL}\` 的设备。"
    echo "提示：由于某些机型（如小米 AX6000 高通版）在特定版本可能下架，建议切换版本查询。"
  } >> $GITHUB_STEP_SUMMARY
else
  echo "✅ 匹配成功！为您精准锁定以下组合："
  echo -e "======================================================="
  
  # 极致对齐逻辑：18字符左对齐，冒号后无空格，确保输出不分大小写且唯一
  FORMATTED_RESULT=$(echo "$RESULT" | awk -F ' : ' '{printf "%-18s:%s\n", $1, $2}' | sort -u)
  
  # 1. 输出到黑框日志
  echo "$FORMATTED_RESULT"
  echo -e "======================================================="
  
  # 2. 输出到 GitHub 首页摘要面板
  {
    echo "### ✅ 匹配成功！为您精准锁定以下组合："
    echo '```text'
    echo "$FORMATTED_RESULT"
    echo '```'
    echo "> 💡 **提示**: 请复制 \`:\` 前后的内容分别填入构建参数的 Arch 和 Profile 中。"
  } >> $GITHUB_STEP_SUMMARY
fi
