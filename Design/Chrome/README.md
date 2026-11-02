# UPasswords · Chrome 扩展设计稿

本目录维护 UPasswords Chrome 扩展（`WebExtensions/chrome`）弹窗 UI 的高保真设计稿。
设计体系与 macOS 端同源（v1 Cupertino Glass），按浏览器弹窗的物理约束做不透明化适配。
目录结构与跨平台约定见 `../README.md`；实现基线以 `popup.html` / `popup.js` 为准。

## 产物

| 文件 | 说明 |
|---|---|
| `UPasswords-chrome-all-ui.svg` | **唯一主源**。2080×2980 画板，15 个分组：01–12 弹窗界面、13–14 边界态、15 设计令牌 |
| `UPasswords-Chrome-All-UI.sketch` | 暗色主题 Sketch 文件（由 SVG 导入生成，图层已命名） |
| `UPasswords-Chrome-All-UI-Light.sketch` | 浅色主题 Sketch 文件（调色板重映射生成） |
| `Previews/dark` / `Previews/light` | 整板渲染预览（sketchtool 导出） |

## 界面清单（分组 id ↔ 功能）

| 分组 id | 界面 | 对应实现 |
|---|---|---|
| `chrome-signin` | 邮箱验证码登录（含 60s 重发冷却态） | `#loginBox` |
| `chrome-connect` | 连接/新建密码库（含超长库名截断） | `#vaultBox` |
| `chrome-unlock` | 主密码解锁（自动锁定说明、无 Touch ID 提示） | `#unlockBox` |
| `chrome-vault` | 密码库列表：站点横幅、当前网站建议、填充/复制、底栏导航 | `#itemsBox` |
| `chrome-detail` | 条目详情只读：TOTP 倒计时环、标签、附件离线保留、泄露警告、字段历史入口 | `#detailBox` |
| `chrome-edit` | 条目编辑：主密码再授权、错误态、内存草稿提示 | `#detailSaveSection` |
| `chrome-new-login` | 新建登录：强度条、网站匹配模式、多网址关联 | `#newLoginBox` |
| `chrome-generator` | 密码生成器：四模式分段控件、长度滑杆、强度条、会话历史 | `#generatorBox` |
| `chrome-settings` | 设置：锁定超时、附件策略、同步状态、备份导出、隔离/冲突入口、账户 | `#settingsBox` |
| `chrome-conflicts` | 同步冲突逐字段裁决（含不可恢复警告） | `#conflictsBox` |
| `chrome-backups` | 本地备份与副本管理（dialog 形态，含不完整清单标记） | `#localBackupManagerDialog` |
| `chrome-local-copy` | 本地副本查看器（「仅本机」徽标、完整性校验、只读字段） | `#localCopyViewerDialog` |
| `chrome-empty-offline` | 边界：空库 / 搜索无结果 / 离线模式 | `#emptyState`、离线分支 |
| `chrome-status-boundary` | 边界：状态条变体、超长文本截断、会话过期、无填充权限、剪贴板/省流量提示 | `#status` 等 |
| `tokens` | 设计令牌与基础组件 | — |

## 设计令牌（暗色 · Ink Aurora 深墨色系）

浏览器弹窗无法呈现 macOS 的透明毛玻璃（弹窗为系统不透明表面），2026-11-01 起采用
**Ink Aurora** 适配：深墨蓝底 + 环境光晕模拟材质纵深，色相与桌面端同源但更克制高级。

- 弹窗底 `#191a20→#14151b`；卡片/工具栏 `#23242c→#1e1f26`；导航/底栏 `#15161c→#121218`
- 环境光晕：弹窗内顶部 `#2f6df2` @9%、底部 `#6d5be2` @6%（`popClip` 裁剪，内容之下）；
  品牌标/hero 图标带 28–30% 同色光晕；主 CTA 顶部 1px 白色高光 @22%
- 输入框 `#0e0f13`（描边 `#3c3d47`，聚焦描边 `#4ea1ff`）；描边层次 `#2e2f39/#383944/#434450`
- 文本：主 `#f4f4f6`，次 `#a5a6af`，弱 `#71727c`；屏标签 `#9a9ba5`
- CTA/强调：精制蓝渐变 `#4ea1ff→#2f6df2`，强调文本 `#5ea6ff`
- 状态（去荧光、更克制）：成功 `#34d399`、警告 `#f6c453`、危险 `#f87171`；徽标用 12–14% 同色相填充
- 头像六色梯度 `av0–av5`（蓝/紫/青/琥珀/玫瑰/绿），按标题哈希取色，对应 `popup.html` 的 `data-tint`
- 外阴影 dy18/blur30 @55%；圆角：卡片 12、按钮/输入 9–10、徽标胶囊 999；8px 网格
- 字体阶梯（弹窗 1×）：屏标题 18/700、面板标题 16/700、条目 13/600、正文 12.5、辅助 11、
  分区标签 10.5/600 字距 .5、等宽密码 mono 12.5–15
- 密码一律掩码，「显示/复制」为明示操作；强度为四段条；TOTP 用倒计时环表达剩余时间

浅色主题由 `../Shared/create-light-theme.mjs` 调色板映射派生（Apple 浅色灰阶 + 精制蓝 `#0057e7`）。

## 边界性设计决策（密码管理器 × 浏览器弹窗）

1. **弹窗即焚**：弹窗关闭即销毁 → 草稿、生成结果、重发倒计时均不可持久。
   涉及草稿的界面（06/07/08）固定展示「仅保留在弹窗内存中」提示，不设计「稍后继续」。
2. **剪贴板不可控**：关闭弹窗后无法可靠清空剪贴板 → 复制入口旁常驻提示（08、14），
   不承诺「自动清除」。
3. **主密码再授权**：编辑保存与新建必须重新输入主密码（06/07），授权区用强调色块与普通
   表单区隔，并明确「不保存主密码或草稿」。
4. **锁定模型**：切换页签不锁定、闲置自动锁定（03、09）；浏览器无生物识别，明确提示
   「桌面端可使用 Touch ID」，不做指纹图标误导。
5. **离线优先**：离线时整体降级为本地加密副本只读（13），同步按钮禁用而非隐藏，
   附件下载遵循省流量/蜂窝策略提示（09、14）。
6. **CSP 与图标**：MV3 扩展页禁止 `data:` 图像 → 图标一律内联 SVG，下拉箭头用纯 CSS
   （实现侧）；设计稿同样全部内联，无外链资源。
7. **文本截断**：标题/用户名/主机名一律单行省略（02/04/14 给出截断示例），
   长文案 `overflow-wrap: anywhere`；双语文案（中/英）均按较长者校核宽度。
8. **尺寸边界**：360–440px 宽、≤600px 高，内容超出滚动；画板按 400×600 标准态绘制，
   360px 窄断点压缩头部与工具栏（见实现 `@media (max-width: 390px)`）。
9. **权限边界**：`chrome://` 等页面无填充权限时站点横幅降级为「当前页面不可填充」（14），
   不展示可点击填充态。
10. **双主题与动效**：`prefers-color-scheme` 双主题同源派生；`prefers-reduced-motion`
    下不做面板切换动画；hover 渐进显示的操作在触屏上常显（见实现 `@media (hover: hover)`）。

## 与桌面端的功能对齐

设计稿按「功能尽可能同桌面端一致」绘制；标 ⚑ 为**设计先行、实现待补**的对齐项：

| 能力 | 桌面端 | 扩展现状 | 设计稿处理 |
|---|---|---|---|
| 搜索/筛选/排序/收藏筛选 | ✓ | ✓ | 04（星标常显，⚑ 点按切换收藏） |
| TOTP 验证码 + 倒计时 | ✓ | ✓（字段渲染） | 05 升级为倒计时环 + 一键复制 |
| 密码生成器 | 四模式 + 历史 | 仅字符集 | 08 补齐 随机/易记短语/PIN/易读 ⚑ + 强度条 ⚑ + 会话历史 ⚑ |
| 泄露检查（HIBP） | ✓ 安全检查 | ✗ | 05 警告徽标 ⚑（仅展示，不重查） |
| 字段历史 | ✓（≤20 旧值） | 部分（历史密文） | 05「3 个历史值」入口 ⚑ |
| 标签 | ✓ | ✗ | 05 标签 chips ⚑（只读展示） |
| 归档/回收站/模板 | ✓ | ✗（协议不含） | 不进入扩展，详情注明「请在桌面端处理」 |
| 二维码录入 TOTP | ✓ | ✗（无摄像头场景） | 06 注明「粘贴或桌面端扫码」 |
| 备份导出/本地副本/冲突裁决 | ✓ | ✓ | 09–12 全量覆盖 |
| 生物识别解锁 | ✓ Touch ID | ✗（浏览器限制） | 03 文案说明，主密码唯一入口 |

## 管线（修改设计后按顺序执行）

```bash
cd Design

# 1. 编辑主源 Chrome/UPasswords-chrome-all-ui.svg
#    （分组 id 稳定；每个界面首条文本为 "NN · 名称" 标签，供图层命名脚本识别）

# 1.5 应用 Ink Aurora 材质与配色（幂等；含标记注释时自动跳过）
node Chrome/refine-premium-ink.mjs

# 2. Sketch 导入并保存
osascript <<'AS'
tell application "Sketch"
  activate
  open (POSIX file "/Users/lizhen/Projects/UPasswords/Design/Chrome/UPasswords-chrome-all-ui.svg")
  delay 10
  set theDoc to front document
  save theDoc in (POSIX file "/Users/lizhen/Projects/UPasswords/Design/Chrome/UPasswords-Chrome-All-UI.sketch")
  close theDoc saving no
end tell
AS

# 3. 重命名图层
node Shared/name-sketch-layers.mjs Chrome/UPasswords-Chrome-All-UI.sketch \
  --page-name "Chrome 扩展全部 UI" \
  --canvas-title "UPasswords · Chrome 扩展 UI 画板" \
  --canvas-group-name "UPasswords Chrome 扩展全部界面画布"

# 4. 生成浅色主题
node Shared/create-light-theme.mjs \
  Chrome/UPasswords-Chrome-All-UI.sketch Chrome/UPasswords-Chrome-All-UI-Light.sketch \
  --page-name "Chrome 扩展浅色主题 · 全部 UI" \
  --canvas-group "UPasswords Chrome 扩展全部界面画布" --canvas-group-light "UPasswords Chrome 浅色主题画布" \
  --board-group "UPasswords-chrome-all-ui" --board-group-light "UPasswords Chrome 扩展 · 浅色主题" \
  --title "UPasswords · Chrome 扩展 UI 画板" --subtitle "v1 · light appearance · editable vector source for Sketch"

# 5. 导出预览
/Applications/Sketch.app/Contents/Resources/sketchtool/bin/sketchtool \
  export artboards Chrome/UPasswords-Chrome-All-UI.sketch \
  --output=Chrome/Previews/dark --export-page-as-fallback=YES
/Applications/Sketch.app/Contents/Resources/sketchtool/bin/sketchtool \
  export artboards Chrome/UPasswords-Chrome-All-UI-Light.sketch \
  --output=Chrome/Previews/light --export-page-as-fallback=YES
```

## 迁移脚本

- `refine-premium-ink.mjs`：2026-11-01 从 Flat Grey 不透明化材质迁移到 Ink Aurora。
  全局色板重映射、弹窗内环境光晕注入（`popClip` 裁剪）、底部导航改悬浮胶囊、
  品牌/hero 光晕、主 CTA 顶部高光、外阴影加深、令牌区重写。幂等（`premium-ink applied` 标记）。

## 注意

- 弹窗为不透明表面，`glassRim` 仅作 1px 高光描边保留材质呼应，不再叠加氛围光晕到界面内部。
- Safari/Edge/Firefox 扩展与 Chrome 共享 `WebExtensions/shared`，视觉规范直接复用本稿；
  Safari 原生容器（`Apple/SafariWebExtension`）的宿主侧 UI 仍属 macOS 稿范畴。
