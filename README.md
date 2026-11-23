# 青果

HarmonyOS 原生短剧聚合播放应用（ArkUI / ArkTS + C++ QuickJS 模块引擎）。

## 功能

- 多站源聚合：内置站源（红果短剧、韩小圈、青空次元、黄豆短剧、鬼片、黑桃、剧果、笔盒等）+ 在线 JS 模块站源（站源商店）
- 播放器：分集播放、选集、倍速、弹幕、横屏、画幅切换、书签、跳片头、多主题
- 音频后台播放：连续性任务 + AVSession 播控与元数据、定时关闭
- 发现 / 片单 / 我的：搜索、追剧、观看记录、继续播放
- 车机流转适配

## 技术架构

- `entry/src/main/ets` — ArkTS 页面、站源实现、播放器、主题与本地存储
- `entry/src/main/cpp` — QuickJS C++ 模块引擎：JS 站源模块在受限沙箱内运行（内存 72MB、栈 384KB、60s deadline、64MB 宿主字节预算），宿主接口提供 fetch/crypto/cache 等能力
- `scripts/` — 21 项 Node 测试（含模块引擎回归测试）
- `handoff/` — 构建 / 设置 / 校验脚本与交接文档

## 开发环境

- DevEco Studio（已验证 26.0.0.865）+ HarmonyOS SDK API 26；最低兼容 `6.1.1(24)`
- Windows PowerShell

## 构建与测试

```powershell
# 测试（21 项）
$env:DEVECO_STUDIO_HOME = "<DevEco Studio 安装目录>"
node scripts/run-tests.cjs

# 构建 + 签名
powershell -ExecutionPolicy Bypass -File .\handoff\Build-Project.ps1
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

## 文档

- [PRODUCT.md](PRODUCT.md) — 产品定位与边界
- [DESIGN.md](DESIGN.md) — 设计规范
- [README-MIGRATION.md](README-MIGRATION.md) — 项目迁移包说明
- [AGENTS.md](AGENTS.md) / [handoff/AGENT_HANDOFF.md](handoff/AGENT_HANDOFF.md) — 开发协作与交接文档
