# imm-packages · AI Edition

这是一个个人自用的 OpenWrt/ImmortalWrt 插件分享仓库。插件以实际使用需求为导向，并借助 AI 完成维护、适配、审计和自动化，因此统一标记为 **AI Edition**。

## 插件简介

| 插件 | 版本 | 简介 | 源码来源 |
| --- | --- | --- | --- |
| `luci-app-axonhub` | `20260717-r1` | AxonHub 的 LuCI 管理界面与 OpenWrt 集成。 | [looplj/axonhub](https://github.com/looplj/axonhub) |
| `luci-app-gecoosac` | `20260717-r1` | gecoosac 的 LuCI 管理界面与 OpenWrt 集成。 | [www.cnrouter.com](http://www.cnrouter.com) |
| `luci-app-homeproxy` | `20260717-r2` | homeproxy 的 LuCI 管理界面与 OpenWrt 集成。 | [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy) |
| `luci-app-wolultra` | `20260717-r2` | WOL Ultra 的 LuCI 管理界面与 OpenWrt 集成。 | [VIKINGYFY/packages](https://github.com/VIKINGYFY/packages) |

## 核心与依赖来源

| 软件包 | 版本 | 源码来源 |
| --- | --- | --- |
| `axonhub` | `20260717-r1` | [looplj/axonhub](https://github.com/looplj/axonhub) |
| `gecoosac` | `2.2.20251015-r1` | [www.cnrouter.com](http://www.cnrouter.com) |
| `sing-box` | `1.14.0_alpha45-r1` | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) |

## 自动维护

CI 每日检查受维护的上游项目，仅在发现更新时继续构建、提交和发布。插件目录通过 Makefile 自动发现；新增或删除插件后，构建范围、发布资产清理和本页插件列表会自动调整。

APK 发布按 ARM64 和 AMD64 分开维护；每个包名保留最近三个版本，并提供包含各插件最新版的整合包。AxonHub 核心发布仅保留最新版，发布说明包含上游最近三次提交信息。

## License

本仓库自有的 CI、脚本、文档及未另行声明的原创内容采用 [MIT License](LICENSE)。各插件、核心程序和预置第三方资源继续遵循其目录或上游项目声明的许可证。
