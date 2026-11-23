# 给下一位 agent 的交接

## 项目与当前目标

“青果”是原生 HarmonyOS 短剧 App，采用 ArkUI/ArkTS、Navigation 和系统 Video，含 C++/N-API 隔离模块运行时。它不是 Android 或 Flutter 项目。用户要求保留名称、功能和数据，已经做过整套 UI 重构；随后要求在线站源商店、Android 播放核心同步及分季移植。最近的分季功能已经实现，当前任务是把可继续开发的完整工作区连同签名交付到另一台电脑。

应用版本 `1.1.1`、versionCode `1001001`，包名 `com.fengjie.qingguo`。记录的 Android 正式版基线是 `Xanerix/guoapp` 的 `app-v2.0.2-114`（`2.0.2+114`），红果内置站源同步至 `1.0.6`。不要未经查验就称为上游“最新版”；这是快照中的同步基线，不表示 Android 所有功能均已移植。

先读根目录 `README-MIGRATION.md` 并运行 `handoff/Setup-Project.ps1 -DevEcoHome <实际路径>`，再运行 `handoff/Build-Project.ps1`。入口脚本按 Windows 环境编写。

## 仓库状态必须保留

- 包内包含 `.git` 和当前工作区，HEAD 是 `0dbc97f`。当前没有配置 Git remote。
- 最新 UI、在线模块、分季和大量修复主要处于未提交/未跟踪状态；不应只看 HEAD 或 Git 已跟踪文件。不要 `reset --hard`、`clean -fd` 或用旧提交覆盖当前工作区。
- 迁移包将 `build-profile.json5` 的签名路径改为项目内相对路径，保留原加密密码。除此之外迁移改动集中在测试路径、脚本和说明，不改变 App 功能。
- `.private-signing/` 是真实签名材料，已经忽略；不要打印密码、私钥，不要上传公开仓库。该目录必须与当前加密密码配套。不要覆盖新机器全局签名配置。

## 架构导航

| 路径 | 用途 |
|---|---|
| `entry/src/main/ets/entryability/EntryAbility.ets` | 启动、本地状态、模块存储和网关初始化；沉浸式窗口、安全区、方向、车机适配 |
| `entry/src/main/ets/pages/Index.ets`、`tab/` | 发现、片单、我的三栏 |
| `entry/src/main/resources/base/profile/router_map.json` | 子页面路由 |
| `entry/src/main/ets/pages/DetailPage.ets` | 详情、选集、分季、追剧、待看 |
| `entry/src/main/ets/pages/PlayerPage.ets` | 播放、续播、重试、切季、跨季连播、弹幕、横屏、设置面板 |
| `entry/src/main/ets/data/QgRepository.ets` | 统一站源入口、模块激活替换、详情/分季缓存、旧请求失效 |
| `entry/src/main/ets/data/source/QgSource.ets` | 站源接口及 ID 管理 |
| `entry/src/main/ets/data/source/QgModuleSource.ets` | 在线模块接口适配、串行调用、分页状态 |
| `entry/src/main/ets/data/QgModuleStore.ets` | 官方索引、哈希检查、两阶段安装、版本持久化及模块状态 |
| `entry/src/main/ets/data/QgModuleHost.ets` | 受限 HTTP、加密、HTML 解析、缓存等宿主能力 |
| `entry/src/main/cpp/qgmodule_engine.cpp`、`qgmodule_napi.cpp` | QuickJS 原生隔离运行时，生成 `libqgmodule.so` |
| `entry/src/main/ets/data/source/HongguoSource.ets` | 红果注册、目录、分季、取流等原生实现 |
| `QgGateway.ets`、`QgCencTask.ets`、`QgMp4Cenc.ets`（data 下） | 媒体凭证、内联 HLS/AES、CENC 解密和 Range |
| `entry/src/main/ets/data/QgStore.ets` | Preferences 观看记录、追剧、待看、设置；必须兼容原键和站源 ID |
| `entry/src/main/ets/data/QgVersion.ets` | 鸿蒙版本及 Android 基线 |

## 已完成的功能与约束

在线站源商店已经能够真正下载并执行 API 1 CommonJS 同步模块，下载核对清单/哈希，检查接口后原子安装。安装后切换站源、重启保留、更新/失败回滚、移除恢复内置实现已覆盖电脑端测试。兼容模块 API 内更新脚本不需再打包；新的宿主能力或 API 升级仍需更新基座。**不要用应用主 JS 的远程 eval 替代隔离 QuickJS。**

红果内置取流采用 GET V5 优先，保留 POST/网页回退、有限的辅助设备/编码重试，避免随意重置主设备身份。网关支持所需凭证、HLS/AES、CENC 和 Range。修改播放时保留原有重试、续播和缓存代际保护。

分季贯通 `QgSeason` → `QgSource.seasons()` → Repository → 详情/播放器。仅使用站源正式系列关系，不按相似标题猜测。在线模块需声明 `seasons` 并导出接口；不支持时返回空列表。

- 手动切季保存旧季进度，恢复目标季自己的集数与时间；自动跨季从下一季第一集开始，遵守 `autoNext`。
- 目标季详情加载失败时保留当前季；快速操作只提交最新请求；旧 resolve、预取、重试及 Video 事件不能覆盖新季。
- 视频未准备好时不能将既有进度覆盖为 0。
- 官方系列任一季元数据不可用则整体报错供重试，避免 `[1,2,3]` 缺第 2 季后变 `[1,3]` 并自动跳季。
- 红果分季整体 25 秒预算包含设备注册，定时器清理，迟到结果不提交。64 位 ID 保留字符串精度。

## 视觉与历史上下文

现行视觉以 `DESIGN.md`、`entry/src/main/ets/components/QgTheme.ets` 和页面实际代码为准，包含三套主题及深浅模式，夜幕青柠框架。用户此前多次否定旧方案，不要根据旧白红截图回退 UI。`.impeccable` 存在历史上下文，不能作为覆盖现有设计的理由；本次迁移不修复这些历史设计文件。

`PRODUCT.md` 中“手机已连接”之类是历史记录，不能当作迁移后的设备状态。`campus-style-lab` 和其他原有实验/资料目录随工作区保留，App 构建入口仍是根目录 Hvigor 工程。

## 工具与验证

已验证环境：DevEco Studio `26.0.0.865`，SDK `API 26 / 26.0.0.105`，Hvigor/OHOS plugin `6.26.9`，OHPM `26.0.0.630`，Node `24.14.1`，SDK CMake `3.28.2`、Clang `15.0.4`，TypeScript `4.9.5`。QuickJS 源码版本 `2026-06-04` 已随项目携带。目标 SDK `26.0.0`，兼容配置 `6.1.1(24)`，C++17，产物 arm64。

`node scripts/run-tests.cjs` 顺序运行 14 项测试并在失败时停止。13 项测试通过共享 `load-typescript.cjs` 从 `DEVECO_STUDIO_HOME` 加载 TS，也支持 `QG_TYPESCRIPT_PATH`；不再要求原 D 盘安装位置。运行时测试依赖 `.cache/module-html-runtime/node_modules/quickjs-emscripten` 及 `.cache/module-work/*-main.js`，已随包携带，不能一概删掉 `.cache`。

测试范围包括站源存储、模块接口/宿主/仓库激活、QuickJS-WASM 隔离、网关、红果 1.0.6/旧接口/注册/V5、播放器重试、分季数据、详情和播放器。Node 测试替换了鸿蒙接口；WASM 不等同于 N-API 真机执行。

当前 1.1.1 已通过 ArkTS、原生模块构建、HAP 签名和 14 项电脑端测试；迁移目录验证结果见 `TRANSFER_VERIFICATION.json`。**1.1.1 未在本次目标手机上实测。** 用户之前要求打包后到另一台电脑安装，不要声称已完成真机检查。

建议下次真机验证：覆盖安装保留数据；商店安装/更新/切换/重启/移除；真实站源浏览与播放；手动切季续播；末集跨季；关闭自动连播；快速切季、弱网失败；横竖屏、沉浸状态栏和弹幕。

账号、榜单、设备管理等其他 Android 可选界面未完整移植。项目迁移不包含手机沙箱内实际观看数据和已装模块状态；不要将源码包等同于手机数据备份。最新安装和功能说明见 `dist/qingguo-1.1.1-README.md`，第三方许可见 `dist/THIRD_PARTY_NOTICES.txt`。
