# UPasswords · macOS 设计稿管线

本目录维护 UPasswords macOS 客户端的高保真设计稿（v1 Cupertino Native 设计系统，macOS 原生风格）。

## 产物

| 文件 | 说明 |
|---|---|
| `UPasswords-macOS-all-ui.svg` | **唯一主源**。3600×10300 画板，含 9 个主窗口 + 03–06 区块（首次运行、全部偏好页签、全部弹窗、系统状态）+ 设计令牌 |
| `UPasswords-macOS-All-UI.sketch` | 暗色主题 Sketch 文件（由 SVG 导入生成，图层已命名） |
| `UPasswords-macOS-All-UI-Light.sketch` | 浅色主题 Sketch 文件（由暗色文件调色板重映射生成） |
| `Previews/` | 重设计前后对比渲染图（由 sketchtool 导出） |

## 管线（修改设计后按顺序执行）

```bash
cd Design

# 1. 编辑主源 SVG（9 个主窗口分组 id/transform 必须保持稳定，
#    name-sketch-layers.mjs 依赖它们重命名图层）

# 2. 追加/重建 03–06 区块（幂等：区块由 COMPLETE-UI-APPENDIX-START/END 标记包裹，
#    重跑前先剥离再重挂；同时兼容旧版无标记布局）
node extend-all-ui.mjs

# 3. 用 Sketch 导入 SVG 并保存为 .sketch（AppleScript）
osascript <<'AS'
tell application "Sketch"
  activate
  open (POSIX file "/Users/lizhen/Projects/UPasswords/Design/UPasswords-macOS-all-ui.svg")
  delay 8
  set theDoc to front document
  save theDoc in (POSIX file "/Users/lizhen/Projects/UPasswords/Design/UPasswords-macOS-All-UI.sketch")
  close theDoc saving no
end tell
AS

# 4. 重命名 Sketch 导入产生的「编组」图层
node name-sketch-layers.mjs UPasswords-macOS-All-UI.sketch

# 5. 生成浅色主题（调色板重映射；会重建 zip 并保留单一 page 条目）
node create-light-theme.mjs
```

## 设计令牌（暗色 Cupertino Native）

- 画布 `#1a1a1e → #101012`；窗口 `#2a2a2f → #232327`（边框 `#43434a`，圆角 14）
- 标题栏/工具栏 `#2e2e34`；侧栏 `#232327 → #1f1f23`，选中胶囊 `#3f3f46`（无描边；列表选中行描边 `#0a84ff`）
- 卡片 `#2a2a30`；次级按钮 `#37373d`（边框 `#4c4c53`）；输入框 `#17171b`（边框 `#48484f`）
- 分隔线 `#3a3a41`；边框 `#43434a`/`#515158`
- 文本：主 `#f5f5f7`/`#ebebf0`，次 `#9c9ca3`/`#8e8e95`，弱 `#6d6d74`
- 主 CTA：系统蓝渐变 `#409cff → #0a84ff` + 白字（渐变 id 仍为 `whiteBtn`，引用兼容）
- 头像渐变 `#409cff → #0a84ff`（id `avatarGrad`）；开关开启态同 CTA 渐变，旋钮恒为白色
- 强调/链接 `#409cff`；成功 `#30d158`；警告 `#ffd60a`；危险 `#ff453a`
- 氛围光晕：画布左上 `#0a84ff` @10%、右下 `#5e5ce6` @5%；锁屏背景 `#1d2029 → #16181f → #131316`
- 标签点缀：工作 `#64d2fc` / 个人 `#bf5af2` / 财务 `#ffd60a`
- 交通灯保留 macOS 标准色 `#ff5f57` / `#febc2e` / `#28c840`
- 字体阶梯（≈1.54×）：窗口标题 17/Semibold，区块标题 26/Semibold，正文 20/Regular，
  辅助 16/Regular，说明 15/Regular，分区标签 15/Semibold（字距 0.8px）；图标与文字按光学中心对齐

浅色映射表见 `create-light-theme.mjs` 顶部 `palette`（Apple 浅色灰阶 + 系统蓝 `#007aff`）。

## 迁移脚本

- `refine-cupertino.mjs`：2026-10-31 从 Aurora Indigo 迁移到 Cupertino Native 的一次性脚本
  （38 处结构细化：图标光学对齐、字重阶梯、开关/滑杆规格统一 + 46 色全局重映射）。幂等；
  对已是新配色的画板执行为无操作，保留用于审计与再次验证。
- `redesign-aurora.mjs`：2026-10 从 Graphite Monochrome 迁移到 Aurora Indigo 的一次性脚本。
  ⚠️ 已被 Cupertino Native 取代，仅留存审计，请勿再执行。

## 注意

- ⚠️ `normalize-theme-consistency.mjs` 已**废弃**（内置旧蓝灰配色映射，运行会破坏新稿），请勿执行。
- `UPasswords-macOS.sketch` 为旧版留存，不在管线内。
- 浅色文件的 `previews/preview.png` 由 Sketch 打开保存后自动刷新。
- 渲染预览：`sketchtool export artboards <file>.sketch --output=<dir> --export-page-as-fallback=YES`
  （`sketchtool` 位于 `/Applications/Sketch.app/Contents/Resources/sketchtool/bin/`）。
