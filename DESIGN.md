---
name: 青果
description: 夜幕 · 青柠 —— 沉浸海报、浮动玻璃控件、青柠实底操作的影院式短剧 App。
colors:
  accent: "#C6F24E"        # 青柠，仅做填充（按钮/选中/进度）
  accent-on: "#0B0F05"     # 青柠之上的文字/图标
  accent-ink-light: "#466A00"  # 浅色模式里落在背景上的青柠文字
  accent-ink-dark: "#C6F24E"
  bg-dark: "#0A0B0A"
  surface-dark: "#141714"
  surface-high-dark: "#1E221E"
  bg-light: "#F3F4EF"      # 月白
  surface-light: "#FFFFFF"
  tab-bar: "#F2121511"     # 两种模式都是墨色浮岛
rounded:
  poster: 18vp
  card: 24vp
  panel: 28vp
  pill: full
spacing:
  gutter: 20vp
  section: 36vp
---

# Design System: 青果 · 夜幕 · 青柠

本轮是对上一版「纯白 · 朱砂」的**完全推翻**：

| | 旧版 纯白 · 朱砂 | 新版 夜幕 · 青柠 |
|---|---|---|
| 基调 | 白底、留白、杂志式 | 影院式、深色优先、海报铺满 |
| 主色 | 朱砂红文字与按钮 | 青柠（呼应「青果」）实底胶囊 |
| 首页 | 左大右小错落海报 | 全幅沉浸轮播 + 海报溢出到状态栏 |
| 导航 | 贴底实色三栏 | 悬浮墨色胶囊岛，选中项青柠展开 |
| 列表 | 等宽双列宫格 | 错落瀑布流 / 巨型描边数字 TOP 榜 |
| 控件 | 浅灰方角块 | 玻璃圆钮 + 全圆胶囊 |

## 规则

1. **青柠只做填充**：`app.color.accent` 用于按钮底、选中胶囊、进度条；其上内容用 `accentOn`。落在背景上的青柠文字/图标用 `accentInk`（浅色模式自动转深橄榄绿，保证对比度）。
2. **玻璃材质**：压在图片上的控件用 `glassBg` + `backdropBlur(20~24)` + 1vp `glassStroke` 描边（组件 `QgIconBtn` / `QgGhostButton`）。
3. **字体层级**：展示标题 30–34fp `FontWeight.Bolder`；区块标题 22fp Bolder，上方英文眉题 10fp 粗体 `letterSpacing(2.4)` 青柠（`QgSectionTitle` 的 `eyebrow`）；正文 14fp；辅助 11–12fp。
4. **圆角**：海报 18、卡片 24、面板/底部弹层 28（仅上方两角）、按钮与胶囊全圆。
5. **边距**：页面左右 20vp；区块间 36vp。底部为悬浮导航预留 `safeBottom + 112`。
6. **沉浸**：系统栏透明。首页、详情页的海报铺到状态栏下方，顶部 `heroTop` 渐变保护状态栏图标，底部渐变到 `bgClear → bg`。
7. **动效**：按压缩放 0.95 + `curves.springMotion`；选中态 220–260ms 弹簧。
8. **播放器**：独立纯黑舞台，控件全部是悬浮玻璃；选集/设置为底部 28 圆角弹层。

## 共享组件（`components/QgWidgets.ets`）

`QgDramaCard`（ratio 可变）、`QgSectionTitle`（eyebrow）、`QgEmptyView`（可带操作）、`QgChip`、`QgIconBtn`、`QgBackBtn`、`QgPrimaryButton`、`QgGhostButton`、`QgSegmented`、`QgTopBar`、`QgUi` 令牌。

## 约束（沿用）

仅保留名称「青果」与全部现有功能：路由、站源密码校验、本地存储、主题切换、播放内核、弹幕、横屏与车机适配。真实内容来自 `QgRepository`，不编造评分/推荐/观看数据。

## 可切换主题 · 2026-11-20

保留青柠、海盐蓝、暖杏的全部原有深浅配色和默认选择，新增四套完整主题：

| 主题 | 浅色 | 深色 | 强调色 |
|---|---|---|---|
| 雾紫 `iris` | 雾白、淡紫灰表面 | 紫黑、烟紫层次 | 柔和鸢尾紫 |
| 蔷薇 `rose` | 玫瑰白、浅粉灰 | 莓黑、灰玫瑰层次 | 干燥花粉 |
| 松玉 `jade` | 玉白、浅青灰 | 深林墨绿 | 清润玉绿 |
| 曜金 `gold` | 暖石白、米灰 | 中性墨色、炭灰 | 香槟浅金 |

四套主题均提供 40 个语义色角色，不单独更改布局、海报或播放行为。主题与系统/浅色/深色模式独立保存；覆盖安装和重启保留当前选择。主题注册表是画廊与存储验证的共同入口，新主题选择与旧 `qg_theme` 键兼容，未知值回退青柠。

设置画廊同时显示日夜迷你界面，以实际背景、表面、强调色及渐变生成预览。正文、辅助文字、强调色上的文字及链接色均做对比度回归；四款新增主题在测试覆盖的实色配对中最低为 4.57:1。视频舞台继续纯黑，播放器面板使用所选主题的深色配色。

颜色角色与深浅模式分别设计，参考 [Material 的颜色角色与成对用色](https://m3.material.io/styles/color/the-color-system/) 及 [Apple 的深色模式层级指导](https://developer.apple.com/design/human-interface-guidelines/dark-mode)。这些原则用于配色与可读性检查，应用仍使用原生 ArkUI 及现有组件。
