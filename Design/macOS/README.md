# UPasswords · macOS 设计稿

本目录维护 UPasswords macOS 客户端的高保真设计稿（v1 Cupertino Glass 设计系统，苹果毛玻璃原生风格）。
目录结构与跨平台约定见 `../README.md`。

## 产物

| 文件 | 说明 |
|---|---|
| `UPasswords-macOS-all-ui.svg` | **唯一主源**。3600×10300 画板，含 9 个主窗口 + 03–06 区块（首次运行、全部偏好页签、全部弹窗、系统状态）+ 设计令牌 |
| `UPasswords-macOS-All-UI.sketch` | 暗色主题 Sketch 文件（由 SVG 导入生成，图层已命名） |
| `UPasswords-macOS-All-UI-Light.sketch` | 浅色主题 Sketch 文件（由暗色文件调色板重映射生成） |
| `Previews/` | 重设计前后对比渲染图（由 sketchtool 导出）；`Previews/glass/` 为 Cupertino Glass 各窗口渲染 |

## 管线（修改设计后按顺序执行）

```bash
cd Design/macOS

# 1. 编辑主源 SVG（9 个主窗口分组 id/transform 必须保持稳定，
#    图层命名脚本依赖它们与 "NN · " 标签重命名图层）

# 2. 追加/重建 03–06 区块（幂等：区块由 COMPLETE-UI-APPENDIX-START/END 标记包裹，
#    重跑前先剥离再重挂；同时兼容旧版无标记布局）
node extend-all-ui.mjs

# 2.5 应用毛玻璃材质与细节校正（幂等；重跑为无操作）
node redesign-frosted-glass.mjs

# 3. 用 Sketch 导入 SVG 并保存为 .sketch（AppleScript）
osascript <<'AS'
tell application "Sketch"
  activate
  open (POSIX file "/Users/lizhen/Projects/UPasswords/Design/macOS/UPasswords-macOS-all-ui.svg")
  delay 8
  set theDoc to front document
  save theDoc in (POSIX file "/Users/lizhen/Projects/UPasswords/Design/macOS/UPasswords-macOS-All-UI.sketch")
  close theDoc saving no
end tell
AS

# 4. 重命名 Sketch 导入产生的「编组」图层（通用脚本在 ../Shared）
node ../Shared/name-sketch-layers.mjs UPasswords-macOS-All-UI.sketch \
  --page-name "macOS 全部 UI" \
  --canvas-title "UPasswords · macOS UI board" \
  --canvas-group-name "UPasswords macOS UI 全部界面" \
  --root-name "UPasswords macOS 全部界面画布" \
  --special "通用+锁定屏幕=偏好设置页签导航"

# 5. 生成浅色主题（调色板重映射；会重建 zip 并保留单一 page 条目）
node ../Shared/create-light-theme.mjs UPasswords-macOS-All-UI.sketch UPasswords-macOS-All-UI-Light.sketch \
  --page-name "macOS 浅色主题 · 全部 UI" \
  --canvas-group "UPasswords macOS 全部界面画布" --canvas-group-light "UPasswords macOS 浅色主题画布" \
  --board-group "UPasswords macOS UI 全部界面" --board-group-light "UPasswords macOS 浅色主题 · 全部界面" \
  --title "UPasswords · macOS Light UI" --subtitle "v1 · light appearance · editable vector source for Sketch"
```

## 设计令牌（暗色 Cupertino Glass）

毛玻璃原则：保留 Cupertino Native 全部色相，材质以透明度叠加在画布氛围光晕之上，
透光产生 frosted glass 质感；浅色主题由同一透明度 + 浅色色相映射自动获得。

- 画布 `#1a1a1e → #101012`；氛围光晕：左上 `#0a84ff` @16%、(3300,2600) `#5e5ce6` @9%、
  (280,5400) `#0a84ff` @8%、(3350,8100) `#5e5ce6` @8%
- 窗口 `#2a2a2f→#232327` @76–82%（边框 `#43434a` @75%，圆角 14）；
  每个窗口底座追加 `glassRim` 内描边（白 28%→4% 顶部高亮渐变，内缩 1px，圆角 13）
- 弹窗底座 `#1e1e22` @74%；标题栏/工具栏/卡片 `#2e2e34` @58%；列表栏 `#232327` @58%；详情栏 `#2a2a2f` @62%
- 侧栏 `#1f1f23→#1a1a1e` @50–55%（最透，齐平全高）；偏好设置侧栏 `#1a1a1e` @50%
- 选中胶囊/图标底 `#3f3f46` @60%；次级按钮/选中行 `#37373d` @60%（边框 `#4c4c53` @80%）
- 输入框 `#17171b` @55%（边框 `#48484f` @80%）；分隔线 `#3a3a41` @60%；开关关态 `#48484f` @65%
- 文本：主 `#f5f5f7`/`#ebebf0`，次 `#9c9ca3`/`#8e8e95`，弱 `#6d6d74`
- 主 CTA：系统蓝渐变 `#409cff → #0a84ff` + 白字（渐变 id 仍为 `whiteBtn`，引用兼容）
- 头像渐变 `#409cff → #0a84ff`（id `avatarGrad`）；开关开启态同 CTA 渐变，旋钮恒为白色
- 强调/链接 `#409cff`；成功 `#30d158`；警告 `#ffd60a`；危险 `#ff453a`
- 锁屏背景 `#1d2029→#16181f→#131316` @72–84%
- 标签点缀：工作 `#64d2fc` / 个人 `#bf5af2` / 财务 `#ffd60a`
- 交通灯保留 macOS 标准色 `#ff5f57` / `#febc2e` / `#28c840`
- 字体阶梯：窗口标题 17/Semibold（基线 y=32，光学中心 = 交通灯中心），区块标题 26/Semibold，
  正文 20/Regular，辅助 16/Regular，说明 15/Regular，分区标签 15/Semibold（字距 0.8px）；
  大标题统一 Semibold；图标与文字按光学中心对齐
- 附录字段行（tile）：label 为无底色弱化文本（13/Medium `#8e8e95`），value 为内凹玻璃字段框
  （`#17171b` @50% + `#48484f` @80% 描边，484×28，圆角 7），与主窗口编辑卡片语言一致；
  正向状态值标绿（精确匹配 开/开启，或含 启用/已同步/有效/很强/已连接），动作文案不标绿
- ⚠️ 图标/logo 一律用 `<g transform="translate scale">` 内联，不用 `<use>`：
  Sketch 导入会忽略 `use` 的 width/height 缩放（92px 主 logo 曾渲染为 28×32）

浅色映射表见 `../Shared/create-light-theme.mjs` 顶部 `palette`（Apple 浅色灰阶 + 系统蓝 `#007aff`）。

## 迁移脚本

- `redesign-frosted-glass.mjs`：2026-10-31 从 Cupertino Native 迁移到 Cupertino Glass（毛玻璃）。
  全局材质透明度注入（fill/stroke/stop-opacity）、glassRim 窗口内描边、氛围光晕增强、
  symbol 内联修正 logo 尺寸、窗口标题基线/开关/字段标签/详情页右缘对齐统一、大标题字重统一。
  幂等；tokens 色板区保持不透明样本。附录区块的玻璃模板内置于 `extend-all-ui.mjs` 的 `tile()`。
- `redesign-main-native.mjs`：2026-10-31 主窗口布局重构，参考 macOS 原生密码管理类应用的三栏样式
  （齐平式侧栏 + 蓝色高亮选中行、扁平列表行 + 圆形钥匙图标/日期/星标/警告三角、
  详情页居中大图标 + 左标签右值字段行 + 底部操作栏）。幂等，整体替换 `main-window` 分组。
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
