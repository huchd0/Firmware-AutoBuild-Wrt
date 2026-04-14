编译时用的是openwrt官方源（极速构建），运行阶段被替换成了科大源（长期维护）

#### 不仅适用于 X86 机器，**  🚀 ImmortalWrt-Embedded-Custom (非x86设备定制固件)  ** 可以给非 x86 架构的路由器（比如红米、华硕、中兴、NanoPi...的硬路由）编译固件！

在嵌入式路由器生态中，芯片平台直接决定设备所属的系统架构（Architecture, 简称 Arch）。例如，红米 AX6000（Redmi AX6000）基于联发科 Filogic 平台，其对应架构为 mediatek-filogic。同时，每一款具体硬件型号还对应一个唯一的设备配置标识（Profile），用于在固件编译或构建过程中精确匹配目标设备。

在嵌入式设备环境中，通常不涉及传统 PC（x86/64）的磁盘分区机制（如 fdisk）、UEFI 启动配置或复杂的网卡驱动适配。因此，也避免了因强制分区操作导致系统无法启动的风险。这使整体流程更加简洁，开发与部署可以聚焦于核心能力，包括：跨架构内核选择、插件集成以及基础网络配置。

为确保信息准确，建议通过🔍 OP Arch & Profile Radar（嵌入式设备寻址雷达）工具查询设备对应的 Arch 与 Profile。

> **💡 提示**：重要提示：在编译 OpenWrt / ImmortalWrt 固件时，若架构（Arch）选择错误，可能导致固件无法刷入或设备变砖。因此，务必事先核对芯片平台对应的 Arch，以及设备专属的 Profile 名称。

需要特别注意的是，OpenWrt/ImmortalWrt 社区中存在一定的“命名历史遗留问题”。例如，在匹配品牌 Xiaomi 时，系统可能会误匹配到包含 “xiaomi” 字符串的设备标识（Profile）（如 xiaomi_redmi-router-ax6000），从而产生了错误的固件。生产固件前需要用工具🔍 OP Arch & Profile Rada（嵌入式设备寻址雷达）交叉查询，设备信息尽量填写多项并且准确。

> 此外，部分高通版本由于其核心加速组件 NSS（Network SubSystem）相关代码为闭源和分区的复杂性的设备，官方并未提供对应镜像支持。这类设备通常无法通过 ImageBuilder 直接生成固件，只能通过完整源码编译实现。

# openwrt-x86-64-build

   极速构建自定义固件大小的 中科大镜像源 openwrt。

   没有过多的软件集成，需要软件后期可以自行安装。

# 基本用法步骤 👈🏻

   1、fork本项目

   2、在fork后的项目中 点击操作【action】 ，左边找到需要的工作流后在右边 运行工作流程【run-workflow】

## 网络配置：

   🌐 后台地址: http://192.168.100.1

   🌍 WAN (外网): 绑定 eth0。

## 固件参数：

  💿 引导格式: squashfs-combined-efi

  🚀 软件源: 中科大镜像源 (USTC)

## 核心功能：

  🛡️ OpenClash (已预装 Meta / Mihomo 内核，直接可用)

  🎨 Argon 主题

  📁 KSMBD 内网共享

  💻 TTYD 网页终端

# OpenWrt 软件包搜索引擎：

  ## https://openwrt.org/packages/index/start
  
  ## https://downloads.openwrt.org/releases/packages-25.12/x86_64/packages/
  
  
   ## 通常在一个版本的完整源路径下（比如 .../x86_64/ 后面），会有以下几个核心文件夹：

   packages/：存放绝大多数第三方命令行工具和核心服务（比如 curl, bash, jq, iperf3, ruby 等）。

   luci/：存放所有带有网页控制面板的插件和主题。比如你要找 luci-app-ttyd、luci-app-samba4 或者带中文的 luci-i18n-xxx-zh-cn，全都在这里面，不在 packages 里。

   base/：存放系统最核心的基础组件和内核模块（比如网卡驱动 kmod-igc、USB驱动 kmod-usb-storage、以及 block-mount 等）。

   routing/：专门存放高级路由协议相关的软件（普通软路由一般用不到）。

## 🌟鸣谢

   https://openwrt.org/
