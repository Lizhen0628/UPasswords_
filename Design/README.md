# UPasswords · 设计稿总览

UPasswords 各平台的高保真设计稿按平台分目录维护，统一使用 Cupertino Glass 设计体系（v1），
主源均为可编辑 SVG，经 Sketch 导入生成 .sketch，再由共享脚本派生浅色主题。

## 目录结构

| 路径 | 平台 | 主源 | 说明 |
|---|---|---|---|
| `macOS/` | macOS 桌面端 | `UPasswords-macOS-all-ui.svg` | 9 主窗口 + 附录区块 + 令牌，3600×10300 画板 |
| `Chrome/` | Chrome 浏览器扩展 | `UPasswords-chrome-all-ui.svg` | 15 个弹窗界面 + 边界态 + 令牌，2080×2980 画板（400×600 弹窗网格） |
| `Shared/` | 跨平台管线脚本 | — | 图层命名与浅色主题生成，供各平台复用 |

新增平台（如 Edge/Firefox/iOS）时：在 `Design/` 下新建 UpperCamelCase 平台目录，
编写平台主源 SVG（分组 id 稳定、界面带 `NN · 名称` 标签），复用 `Shared/` 管线，并在平台
README 记录该平台的设计令牌适配与边界决策。

## 通用管线（各平台一致）

```bash
# 1. 编辑平台主源 SVG（界面分组保持 id 稳定，首条文本为 "NN · 名称" 标签，
#    name-sketch-layers.mjs 依赖它们重命名图层）

# 2. 用 Sketch 导入 SVG 并保存为 .sketch（AppleScript，替换路径与文件名）
osascript <<'AS'
tell application "Sketch"
  activate
  open (POSIX file "<平台目录>/<主源>.svg")
  delay 10
  set theDoc to front document
  save theDoc in (POSIX file "<平台目录>/<暗色>.sketch")
  close theDoc saving no
end tell
AS

# 3. 重命名 Sketch 导入产生的「编组」与 SVG id 图层（幂等）
node Shared/name-sketch-layers.mjs <暗色>.sketch \
  --page-name "<页面名>" --canvas-title "<画板标题文本>" \
  --canvas-group-name "<画布分组名>" [--special "标签A+标签B=分组名"]

# 4. 生成浅色主题（Cupertino 调色板重映射；会重建 zip）
node Shared/create-light-theme.mjs <暗色>.sketch <浅色>.sketch \
  --page-name "<浅色页面名>" [--canvas-group ... --board-group ... --title ... --subtitle ...]

# 5. 导出预览
/Applications/Sketch.app/Contents/Resources/sketchtool/bin/sketchtool \
  export artboards <file>.sketch --output=<平台目录>/Previews/<主题> --export-page-as-fallback=YES
```

## 跨平台约定

- 设计令牌同源：暗色 Cupertino Glass 色板（`#409cff→#0a84ff` 系统蓝渐变、
  `#30d158/#ffd60a/#ff453a` 状态色）；浅色由同一映射表派生，禁止手工另调。
- 图标/logo 一律 `<g transform="translate scale">` 内联，不用 `<use>`
  （Sketch 导入会忽略 `use` 的 width/height 缩放）。
- 密码、密钥等敏感内容在设计稿中同样只以掩码/示例占位呈现。
- 各平台目录 README 记录该平台专属的边界约束（如弹窗尺寸、CSP、会话生命周期）。
