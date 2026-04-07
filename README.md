# openwrt-x86-64-build

   一个工作流，极速构建，自定义固件大小的 中科大镜像源 openwrt。

   没有过多的软件集成，需要软件后期可以自行安装。

基本用法步骤 👈🏻

   1、fork本项目

   2、在fork后的项目中 点击操作【action】 ，左边找到需要的工作流后在右边 运行工作流程【run-workflow】

网络配置：

   🌐 后台地址: http://192.168.100.1

   🌍 WAN (外网): 绑定 eth0。

固件参数：

  💿 引导格式: squashfs-combined-efi

  🚀 软件源: 中科大镜像源 (USTC)

核心功能：

  🛡️ OpenClash (已预装 Meta / Mihomo 内核，直接可用)

  🎨 Argon 主题 (默认启用)

  📁 KSMBD 极速内网共享

  💻 TTYD 网页终端

🌟鸣谢

   https://openwrt.org/
