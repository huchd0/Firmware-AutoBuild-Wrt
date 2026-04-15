#!/bin/bash

# =========================================================
# 0. 准备动态初始化脚本 (按需生成相关配置)
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"

echo "#!/bin/sh" > $DYNAMIC_SCRIPT
echo "uci set network.lan.ipaddr='$CUSTOM_IP'" >> $DYNAMIC_SCRIPT

# =========================================================
# 1. 隐式底层强化包 (无论如何都会安装的无感神器)
# =========================================================
BASE_PACKAGES=""
# 系统与中文
BASE_PACKAGES="$BASE_PACKAGES base-files block-mount default-settings-chn luci-i18n-base-zh-cn"
# 性能与底层工具 (无界面)
BASE_PACKAGES="$BASE_PACKAGES irqbalance zram-swap iperf3 htop curl wget-ssl kmod-virtio-net kmod-vmxnet3"

# 🟢 隐式预装的小巧实用界面工具 (移出了 GitHub Action 选项卡)
BASE_PACKAGES="$BASE_PACKAGES luci-app-ttyd luci-i18n-ttyd-zh-cn"                   # Web 终端
BASE_PACKAGES="$BASE_PACKAGES luci-app-upnp luci-i18n-upnp-zh-cn"                   # UPnP 端口映射
BASE_PACKAGES="$BASE_PACKAGES luci-app-wol luci-i18n-wol-zh-cn"                     # 网络唤醒
BASE_PACKAGES="$BASE_PACKAGES luci-app-ramfree luci-i18n-ramfree-zh-cn"             # 一键释放内存
BASE_PACKAGES="$BASE_PACKAGES luci-app-filetransfer luci-i18n-filetransfer-zh-cn"   # 网页文件传输
BASE_PACKAGES="$BASE_PACKAGES luci-app-autoreboot luci-i18n-autoreboot-zh-cn"       # 定时重启
# 隐式工具的预设配置 (定时重启默认开启：每天凌晨4点)
echo "uci set autoreboot.@autoreboot[0].enable='1'" >> $DYNAMIC_SCRIPT
echo "uci set autoreboot.@autoreboot[0].hour='4'" >> $DYNAMIC_SCRIPT
echo "uci set autoreboot.@autoreboot[0].minute='0'" >> $DYNAMIC_SCRIPT

# =========================================================
# 2. 根据选项，动态追加【核心软件、中文包及专属设置】
# =========================================================

# 🎨 Argon 主题 (无控制面板)
if [ "$THEME_ARGON" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
    echo "uci set luci.main.mediaurlbase='/luci-static/argon'" >> $DYNAMIC_SCRIPT
fi

# 🛡️ 科学类
if [ "$APP_HOMEPROXY" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
fi
if [ "$APP_OPENCLASH" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash" # OpenClash 自带多语言
fi
if [ "$APP_PASSWALL" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"
fi

# 📁 存储与下载类
if [ "$APP_KSMBD" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
    echo "uci set ksmbd.globals.workgroup='WORKGROUP'" >> $DYNAMIC_SCRIPT
    echo "uci set ksmbd.globals.description='ImmortalWrt NAS'" >> $DYNAMIC_SCRIPT
fi
if [ "$APP_ALIST" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-alist luci-i18n-alist-zh-cn"
fi
if [ "$APP_QBITTORRENT" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"
fi

# 🛑 广告拦截
if [ "$APP_ADGUARDHOME" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-adguardhome luci-i18n-adguardhome-zh-cn"
fi

# ⚖️ MWAN3 负载均衡/多拨
if [ "$APP_MWAN3" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-mwan3 luci-i18n-mwan3-zh-cn"
fi

# 🔑 KMS 激活
if [ "$APP_VLMCSD" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-vlmcsd luci-i18n-vlmcsd-zh-cn"
    echo "uci set vlmcsd.config.enabled='1'" >> $DYNAMIC_SCRIPT
    echo "uci set vlmcsd.config.autoactivate='1'" >> $DYNAMIC_SCRIPT
fi

# 📊 状态监控与 QoS
if [ "$APP_STATISTICS" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn"
    BASE_PACKAGES="$BASE_PACKAGES collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory collectd-mod-network"
    echo "uci set luciplugins.statistics.enable='1'" >> $DYNAMIC_SCRIPT
fi
if [ "$APP_SQM" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-sqm luci-i18n-sqm-zh-cn"
fi

# 🕸️ VPN 与穿透组网
if [ "$APP_WIREGUARD" = "true" ]; then
    # 注意：WireGuard 独立中文包已弃用，因此这里没有 i18n
    BASE_PACKAGES="$BASE_PACKAGES luci-proto-wireguard luci-app-wireguard"
fi
# 🕸️ Tailscale 异地组网
if [ "$APP_TAILSCALE" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-tailscale"
fi
if [ "$APP_ZEROTIER" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn"
fi
if [ "$APP_FRPC" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-frpc luci-i18n-frpc-zh-cn"
fi

# =========================================================
# 3. 实体网卡驱动 (严格按需加载)
# =========================================================

if [ "$KMOD_IGC" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-igc"                         # Intel i225/i226
fi
if [ "$KMOD_IXGBE" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-ixgbe"                       # Intel 10G
fi
if [ "$KMOD_E1000E" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-e1000e"                      # Intel 千兆
fi
if [ "$KMOD_R8169" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-r8169"                       # Realtek 瑞昱千兆
fi
if [ "$KMOD_R8125" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-r8125"                       # Realtek 瑞昱 2.5G
fi

# 🐳 Docker 组件
if [ "$INCLUDE_DOCKER" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"
fi

# =========================================================
# 4. 封装并执行配置保存，最后清理自毁
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

echo ">>> 最终打包的软件列表: $BASE_PACKAGES"

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
