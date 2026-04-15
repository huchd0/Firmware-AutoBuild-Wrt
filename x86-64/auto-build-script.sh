#!/bin/bash

# =========================================================
# 0. 准备动态初始化脚本 (按需生成相关配置)
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"

echo "#!/bin/sh" > $DYNAMIC_SCRIPT
echo "uci set network.lan.ipaddr='$CUSTOM_IP'" >> $DYNAMIC_SCRIPT

# =========================================================
# 1. 定义基础软件包 (底层必需)
# =========================================================
BASE_PACKAGES=""
BASE_PACKAGES="$BASE_PACKAGES base-files"                # 基础文件系统结构
BASE_PACKAGES="$BASE_PACKAGES block-mount"               # 磁盘挂载核心支持
BASE_PACKAGES="$BASE_PACKAGES default-settings-chn"      # 默认中国区设置与时区
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-base-zh-cn"      # LuCI 后台中文语言包

# =========================================================
# 2. 根据选项，动态追加【软件、中文包及专属设置】
# =========================================================

# 🎨 Argon 主题 (去除了控制面板)
if [ "$THEME_ARGON" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"                 # 主题核心
    # 强制设为默认主题
    echo "uci set luci.main.mediaurlbase='/luci-static/argon'" >> $DYNAMIC_SCRIPT
fi

# 🛡️ HomeProxy 代理
if [ "$APP_HOMEPROXY" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy"               # HomeProxy 核心
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-homeproxy-zh-cn"        # HomeProxy 中文包
fi

# 🔌 OpenClash 备用
if [ "$APP_OPENCLASH" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"               # OpenClash 核心与界面
fi

# 📁 KSMBD 文件共享
if [ "$APP_KSMBD" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd"                   # KSMBD 服务端与界面
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-ksmbd-zh-cn"            # KSMBD 中文包
    # KSMBD 默认组与描述配置
    echo "uci set ksmbd.globals.workgroup='WORKGROUP'" >> $DYNAMIC_SCRIPT
    echo "uci set ksmbd.globals.description='ImmortalWrt NAS'" >> $DYNAMIC_SCRIPT
fi

# 📊 Statistics 状态监控
if [ "$APP_STATISTICS" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics"              # 统计核心与界面
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-statistics-zh-cn"       # 统计组件中文包
    BASE_PACKAGES="$BASE_PACKAGES collectd"                         # 数据收集守护进程
    BASE_PACKAGES="$BASE_PACKAGES collectd-mod-cpu"                 # CPU 监控插件
    BASE_PACKAGES="$BASE_PACKAGES collectd-mod-interface"           # 网卡监控插件
    BASE_PACKAGES="$BASE_PACKAGES collectd-mod-memory"              # 内存监控插件
    BASE_PACKAGES="$BASE_PACKAGES collectd-mod-network"             # 网络流控监控
    # 启用统计服务
    echo "uci set luciplugins.statistics.enable='1'" >> $DYNAMIC_SCRIPT
fi

# ⏱️ AutoReboot 定时重启
if [ "$APP_AUTOREBOOT" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-autoreboot"              # 定时重启功能
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-autoreboot-zh-cn"       # 定时重启中文包
    # 默认每天凌晨 4 点重启
    echo "uci set autoreboot.@autoreboot[0].enable='1'" >> $DYNAMIC_SCRIPT
    echo "uci set autoreboot.@autoreboot[0].hour='4'" >> $DYNAMIC_SCRIPT
    echo "uci set autoreboot.@autoreboot[0].minute='0'" >> $DYNAMIC_SCRIPT
fi

# 🎮 UPnP 端口映射
if [ "$APP_UPNP" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-upnp"                    # 自动端口映射服务
fi

# 📟 TTYD Web 终端
if [ "$APP_TTYD" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-ttyd"                    # Web 终端控制台
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-ttyd-zh-cn"             # 终端控制台中文包
fi

# 🛡️ WireGuard VPN
if [ "$APP_WIREGUARD" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-proto-wireguard"             # WireGuard 协议支持
    BASE_PACKAGES="$BASE_PACKAGES luci-app-wireguard"               # WireGuard 状态界面
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-wireguard-zh-cn"        # WireGuard 中文包
fi

# 🕸️ Tailscale 异地组网
if [ "$APP_TAILSCALE" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-tailscale"               # Tailscale 控制界面
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-tailscale-zh-cn"        # Tailscale 中文包
fi

# 🚦 SQM QoS 网络流控
if [ "$APP_SQM" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-sqm"                     # SQM QoS 核心与界面
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-sqm-zh-cn"              # SQM QoS 中文包
fi

# 🔑 KMS 激活服务
if [ "$APP_VLMCSD" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-vlmcsd"                  # KMS 激活服务界面
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-vlmcsd-zh-cn"           # KMS 服务中文包
    # 默认开机启用并自动激活
    echo "uci set vlmcsd.config.enabled='1'" >> $DYNAMIC_SCRIPT
    echo "uci set vlmcsd.config.autoactivate='1'" >> $DYNAMIC_SCRIPT
fi

# =========================================================
# 3. 按需独立处理网卡驱动 (取代全集，保持纯净)
# =========================================================

if [ "$KMOD_IGC" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-igc"                         # Intel i225/i226 2.5G 网卡驱动
fi
if [ "$KMOD_IXGBE" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-ixgbe"                       # Intel 10G 万兆网卡驱动
fi
if [ "$KMOD_E1000E" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-e1000e"                      # Intel 千兆网卡驱动
fi
if [ "$KMOD_R8169" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-r8169"                       # Realtek 瑞昱千兆网卡驱动
fi
if [ "$KMOD_R8125" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-r8125"                       # Realtek 瑞昱 2.5G 网卡驱动
fi
if [ "$KMOD_VMXNET3" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-vmxnet3"                     # VMware 虚拟网卡驱动
fi
if [ "$KMOD_VIRTIO" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES kmod-virtio-net"                  # PVE/KVM 虚拟网卡驱动
fi

# 🐳 Docker 组件
if [ "$INCLUDE_DOCKER" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman"               # Docker 控制面板
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-dockerman-zh-cn"        # Docker 面板中文包
    BASE_PACKAGES="$BASE_PACKAGES docker-compose"                   # Docker 编排工具
fi

# =========================================================
# 4. 封装并执行配置保存，最后清理自毁
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

echo ">>> 最终打包的软件列表: $BASE_PACKAGES"

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
