编译时用的是openwrt官方源（极速构建），运行阶段被替换成了科大源（长期维护）

#### 不仅适用于 X86 机器，**  🚀 ImmortalWrt-Embedded-Custom (非x86设备定制固件)  ** 可以给非 x86 架构的路由器（比如红米、华硕、中兴、NanoPi...的硬路由）编译固件！

嵌入式路由器中芯片决定属于哪个架构(arch)，如红米 AX6000 (Redmi AX6000)就是：mediatek-filogic，每一个具体的硬件型号都有自己专属的 Profile 名称，查询方式请用查询工具：OP Arch & Profile Radar (设备号智能寻址雷达)

嵌入式设备上，强制执行分区操作往往会导致系统无法启动，所以没有分区报错风险，逻辑也会变得非常简单，因为没有了所有复杂的磁盘分区（fdisk）、UEFI 设置以及针对 PC 的网卡驱动，将专注于嵌入式路由器的核心需求：跨架构内核下载、插件集成和基础网络配置。

> **💡 提示**：在 OpenWrt/ImmortalWrt 编译时，**架构 (Arch)** 选错会导致固件无法运行（变砖）或无法刷入。请务必先核对芯片型号对应的架构(arch)和硬件设备专属的 Profile 名称。（比如：OpenWrt/ImmortalWrt 社区的一个“命名历史遗留问题，匹配品牌xiaomi时会出现redmi，由于红米 AX6000 的全名是 xiaomi_redmi-router-ax6000，它完美包含了 xiaomi，所以被引擎“由于太匹配”而抓取了出来，小米AX6000高通芯片的灵魂NSS部分代码是闭源原因，没有收录高通版小米 AX6000 的镜像，这种情况就很容易出错了，但只要架构(arch)和硬件设备专属的 Profile 名称填写正确，那只要官方的镜像存在生成的固件也会是正确的，如果官方盲搜都搜不到，说明这款机器只能通过 “源码编译” 而非我们的“ImageBuilder”可以完成的了。）

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
