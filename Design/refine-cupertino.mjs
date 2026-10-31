import { readFile, writeFile } from 'node:fs/promises';

// refine-cupertino.mjs — 2026-10-31 从 Aurora Indigo 迁移到 Cupertino Native（macOS 原生风格）。
// 职责一：细节打磨（图标光学对齐、字重阶梯、控件规格统一）。
// 职责二：全局调色板重映射（蓝紫调 → 中性灰 + 系统蓝），单遍替换，幂等（旧色值替换完即无操作）。
// 对 tokens 区块内展示用的十六进制文本同样生效，保证色板标注与实色一致。

const path = new URL('./UPasswords-macOS-all-ui.svg', import.meta.url);
let svg = await readFile(path, 'utf8');

let structuralChanges = 0;
function replace(oldStr, newStr, { all = false } = {}) {
  if (all) {
    const count = svg.split(oldStr).length - 1;
    if (count === 0) return;
    svg = svg.replaceAll(oldStr, newStr);
    structuralChanges += count;
    return;
  }
  if (!svg.includes(oldStr)) return;
  svg = svg.replace(oldStr, newStr);
  structuralChanges += 1;
}

// ── 1. 字体阶梯（Apple HIG：窗口标题 semibold，分区标题字距收敛）────────────
replace('.section { font-size:15px; font-weight:600; letter-spacing:1.6px; }',
  '.section { font-size:15px; font-weight:600; letter-spacing:.8px; }');
replace('.title { font-size:26px; font-weight:700; }',
  '.title { font-size:26px; font-weight:600; }');
replace('font-size="17" font-weight="700"', 'font-size="17" font-weight="600"', { all: true });

// ── 2. 侧栏图标：描边 1.8 → 2（SF Symbols regular 手感），光学中心对齐文字 ──
replace('stroke-width="1.8"', 'stroke-width="2"', { all: true });
// 图标盒中心 = 文字基线 - 7（20px 字体的光学中心），三行统一下移 4px
replace('transform="translate(44 244) scale(0.75)"', 'transform="translate(44 248) scale(0.75)"');
replace('transform="translate(44 282) scale(0.75)"', 'transform="translate(44 286) scale(0.75)"');
replace('transform="translate(44 320) scale(0.75)"', 'transform="translate(44 324) scale(0.75)"');

// ── 3. 列表行：警告圆点对齐副标题光学中心 ─────────────────────────────────
replace('<circle cx="550" cy="219" r="4" fill="#fbbf24"/>', '<circle cx="550" cy="213" r="4" fill="#fbbf24"/>');

// ── 4. 详情页：收藏星标对齐大标题光学中心 ─────────────────────────────────
replace('<circle cx="1450" cy="164" r="19" fill="#20263a" stroke="#2f3854"/>',
  '<circle cx="1450" cy="155" r="19" fill="#20263a" stroke="#2f3854"/>');
replace('<text x="1450" y="171" class="muted" font-size="21" text-anchor="middle">☆</text>',
  '<text x="1450" y="162" class="muted" font-size="21" text-anchor="middle">☆</text>');

// ── 5. 工具栏溢出按钮：文字「•••」→ 三点圆点（SF Symbol ellipsis），修正居中 ──
replace('<text x="1409" y="95" class="label body">•••</text>',
  '<g fill="#e7ecf7"><circle cx="1411" cy="89" r="2"/><circle cx="1417" cy="89" r="2"/><circle cx="1423" cy="89" r="2"/></g>');

// ── 6. 底部按钮文字垂直居中（20px 字体：基线 = 按钮中心 + 7）─────────────
replace('y="776"', 'y="778"', { all: true });

// ── 7. 开关：关态旋钮改白色（Apple 规范旋钮恒为白色，轨道表达状态）─────────
replace('fill="#6b7590"', 'fill="#ffffff"', { all: true });
// 生成器开关统一为 38×22 规格（与偏好设置一致）
replace('<rect x="500" y="268" width="42" height="24" rx="12" fill="url(#whiteBtn)"/><circle cx="530" cy="280" r="9" fill="#ffffff"/>',
  '<rect x="504" y="269" width="38" height="22" rx="11" fill="url(#whiteBtn)"/><circle cx="527" cy="280" r="8" fill="#ffffff"/>');
replace('<rect x="500" y="316" width="42" height="24" rx="12" fill="url(#whiteBtn)"/><circle cx="530" cy="328" r="9" fill="#ffffff"/>',
  '<rect x="504" y="317" width="38" height="22" rx="11" fill="url(#whiteBtn)"/><circle cx="527" cy="328" r="8" fill="#ffffff"/>');
replace('<rect x="500" y="364" width="42" height="24" rx="12" fill="#2c3450"/><circle cx="512" cy="376" r="9" fill="#ffffff"/>',
  '<rect x="504" y="365" width="38" height="22" rx="11" fill="#2c3450"/><circle cx="515" cy="376" r="8" fill="#ffffff"/>');

// ── 8. 滑杆旋钮：白色 + 细描边（Apple 滑杆手感）──────────────────────────
replace('<circle cx="374" cy="236" r="9" fill="url(#avatarGrad)"/>',
  '<circle cx="374" cy="236" r="10" fill="#ffffff" stroke="#242b3d" stroke-width="1"/>');

// ── 9. 设置向导进度条：已完成段使用强调色而非纯白 ─────────────────────────
replace('<line x1="90" y1="310" x2="420" y2="310" stroke="#f2f5fc" stroke-width="3" stroke-linecap="round"/>',
  '<line x1="90" y1="310" x2="420" y2="310" stroke="#0a84ff" stroke-width="3" stroke-linecap="round"/>');

// ── 10. 侧栏选中胶囊去掉描边（macOS 原生选中态无描边）─────────────────────
replace('<rect x="30" y="150" width="226" height="40" rx="10" fill="#252c42" stroke="#2f3854"/>',
  '<rect x="30" y="150" width="226" height="40" rx="10" fill="#252c42"/>');

// ── 11. 设计系统更名 ─────────────────────────────────────────────────────
replace('v1 · aurora indigo system · editable vector source for Sketch',
  'v1 · cupertino native system · editable vector source for Sketch');
replace('Tokens · 设计语言 · Aurora Indigo', 'Tokens · 设计语言 · Cupertino Native');
replace('Window Title · 26 / Bold', 'Window Title · 26 / Semibold');

// ── 11b. 侧栏品牌区：图标与文字留出 12px 间距 ────────────────────────────
replace('<use href="#vault" x="40" y="78" width="20" height="20"/><text x="68" y="94" class="muted small">UPasswords</text>',
  '<use href="#vault" x="40" y="78" width="20" height="20"/><text x="72" y="94" class="muted small">UPasswords</text>');

// ── 12. 全局调色板重映射：Aurora Indigo → Cupertino Native ───────────────
// 单遍正则替换，键值不会链式再映射；交通灯三色与 #ffffff 刻意保留。
const palette = new Map(Object.entries({
  // 画布 / 窗口铬层（蓝调深灰 → 中性灰）
  '#08090e': '#101012',
  '#0a0c14': '#131316',
  '#0d1017': '#1a1a1e',
  '#0e1018': '#1f1f23',
  '#0e111a': '#17171b',
  '#10131c': '#232327',
  '#12151f': '#1e1e22',
  '#12162a': '#16181f',
  '#151926': '#26262b',
  '#171b28': '#2a2a2f',
  '#181c2a': '#2e2e34',
  '#1a1f2e': '#2a2a30',
  '#1b2140': '#1d2029',
  '#20263a': '#37373d',
  // 选中 / 头像底
  '#252c42': '#3f3f46',
  '#232a3f': '#3f3f46',
  // 分隔线 / 边框
  '#242b3d': '#3a3a41',
  '#252c3e': '#3a3a41',
  '#283049': '#43434a',
  '#2c3450': '#48484f',
  '#2f3854': '#4c4c53',
  '#313a56': '#515158',
  '#3d4767': '#5c5c63',
  // 选中行描边 → 系统蓝
  '#4f5bd5': '#0a84ff',
  // 文本前景
  '#f2f5fc': '#f5f5f7',
  '#e7ecf7': '#ebebf0',
  '#d6ddeb': '#d5d5db',
  '#b8c2d8': '#aeaeb3',
  '#8f99b3': '#9c9ca3',
  '#7e88a3': '#8e8e95',
  '#6b7590': '#7a7a81',
  '#5a6480': '#6d6d74',
  // 强调 / 渐变 / 光晕 → 系统蓝族
  '#818cf8': '#409cff',
  '#8f9bf9': '#409cff',
  '#6366f1': '#0a84ff',
  '#8b5cf6': '#5e5ce6',
  // 状态色 → Apple 系统色（深色）
  '#34d399': '#30d158',
  '#fbbf24': '#ffd60a',
  '#f87171': '#ff453a',
  // 标签点缀 → Apple 系统色（深色）
  '#7dd3fc': '#64d2fc',
  '#c4b5fd': '#bf5af2',
  '#fcd34d': '#ffd60a',
}));

const pattern = new RegExp([...palette.keys()].join('|'), 'g');
let remappedColors = 0;
svg = svg.replace(pattern, match => {
  remappedColors += 1;
  return palette.get(match);
});

await writeFile(path, svg);
console.log(`Refined to Cupertino Native: ${structuralChanges} structural edits, ${remappedColors} color values remapped.`);
