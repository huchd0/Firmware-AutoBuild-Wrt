GitHub 编译时用的是openwrt官方源（极速构建），运行阶段被替换成了科大源（长期维护）

不仅适用于 X86 机器，build_embedded.sh 可以给非 x86 架构的路由器（比如红米、华硕的硬路由）编译固件！

嵌入式路由器中芯片决定属于哪个架构(arch)，每一个具体的硬件型号都有自己专属的 Profile 名称。

嵌入式设备上，强制执行分区操作往往会导致系统无法启动，所以没有分区报错风险，逻辑也会变得非常简单，因为没有了所有复杂的磁盘分区（fdisk）、UEFI 设置以及针对 PC 的网卡驱动，将专注于嵌入式路由器的核心需求：跨架构内核下载、插件集成和基础网络配置。

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
