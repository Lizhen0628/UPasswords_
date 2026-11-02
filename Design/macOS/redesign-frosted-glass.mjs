import { readFile, writeFile } from 'node:fs/promises';

// redesign-frosted-glass.mjs — 2026-10-31 从 Cupertino Native 迁移到 Cupertino Glass（苹果毛玻璃原生风格）。
// 职责一：材质化 —— 窗口/侧栏/工具栏/卡片/控件保留原有色相，统一注入透明度（fill-opacity /
//   stop-opacity / stroke-opacity），让画布氛围光晕透过各层材质，形成 frosted glass 质感；
//   每个窗口底座追加 glassRim 内描边（顶部高亮渐变），模拟玻璃边缘反光。
// 职责二：细节校正 —— 窗口标题基线统一、工具栏标题块光学居中、开关/字段标签垂直对齐、
//   详情页右缘对齐统一、字重阶梯统一（大标题 700 → 600）。
// 全部替换精确匹配旧串，替换过即不再命中，幂等；tokens 色板区与附录区块（由
//   extend-all-ui.mjs 玻璃模板生成）不在本脚本处理范围内，避免色板样本被透明化。

const path = new URL('./UPasswords-macOS-all-ui.svg', import.meta.url);
let svg = await readFile(path, 'utf8');

let changes = 0;
function replace(oldStr, newStr, { all = false } = {}) {
  if (all) {
    const count = svg.split(oldStr).length - 1;
    if (count === 0) return;
    svg = svg.replaceAll(oldStr, newStr);
    changes += count;
    return;
  }
  if (!svg.includes(oldStr)) return;
  svg = svg.replace(oldStr, newStr);
  changes += 1;
}

// ── 1. 渐变材质：窗口/侧栏/锁屏背景注入 stop-opacity（毛玻璃透光核心）────────
replace(`<linearGradient id="window" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2a2a2f"/>
      <stop offset="1" stop-color="#232327"/>
    </linearGradient>`,
`<linearGradient id="window" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2a2a2f" stop-opacity=".76"/>
      <stop offset="1" stop-color="#232327" stop-opacity=".82"/>
    </linearGradient>`);
replace(`<linearGradient id="sidebar" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1f1f23"/>
      <stop offset="1" stop-color="#1a1a1e"/>
    </linearGradient>`,
`<linearGradient id="sidebar" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1f1f23" stop-opacity=".5"/>
      <stop offset="1" stop-color="#1a1a1e" stop-opacity=".55"/>
    </linearGradient>`);
replace(`<linearGradient id="lockBg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1d2029"/>
      <stop offset="0.5" stop-color="#16181f"/>
      <stop offset="1" stop-color="#131316"/>
    </linearGradient>`,
`<linearGradient id="lockBg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1d2029" stop-opacity=".72"/>
      <stop offset="0.5" stop-color="#16181f" stop-opacity=".78"/>
      <stop offset="1" stop-color="#131316" stop-opacity=".84"/>
    </linearGradient>`);

// 玻璃边缘反光渐变（顶部亮、底部弱），作为各窗口的内描边
if (!svg.includes('id="glassRim"')) {
  replace(`<linearGradient id="whiteBtn"`,
`<linearGradient id="glassRim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".28"/>
      <stop offset="0.12" stop-color="#ffffff" stop-opacity=".09"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity=".04"/>
    </linearGradient>
    <linearGradient id="whiteBtn"`);
  changes += 1;
}

// ── 2. 氛围光晕：增强透底亮度，并向附录区块延伸两束环境光 ────────────────────
replace('<ellipse cx="900" cy="-200" rx="1400" ry="600" fill="#0a84ff" opacity=".10" filter="url(#soft)"/>',
  '<ellipse cx="900" cy="-200" rx="1400" ry="600" fill="#0a84ff" opacity=".16" filter="url(#soft)"/>');
replace('<ellipse cx="3300" cy="2600" rx="1200" ry="800" fill="#5e5ce6" opacity=".05" filter="url(#soft)"/>',
`<ellipse cx="3300" cy="2600" rx="1200" ry="800" fill="#5e5ce6" opacity=".09" filter="url(#soft)"/>
  <ellipse cx="280" cy="5400" rx="1000" ry="700" fill="#0a84ff" opacity=".08" filter="url(#soft)"/>
  <ellipse cx="3350" cy="8100" rx="1100" ry="800" fill="#5e5ce6" opacity=".08" filter="url(#soft)"/>`);

// ── 2b. 内联 symbol 实例：Sketch 导入 <use> 时忽略 width/height 缩放，
// 导致锁屏 92px 主 logo 渲染为 28×32、工具栏加号 24px 渲染为 14px。
// 改为 translate + scale 的显式编组，保证每个 logo / 图标的尺寸与位置像素级精确。
const symbolContent = {
  vault: '<path d="M20 4l14 7v18l-14 7L6 29V11z" fill="#f5f5f7" fill-opacity=".08" stroke="#f5f5f7" stroke-width="2"/><circle cx="20" cy="20" r="8" fill="none" stroke="#aeaeb3" stroke-width="2"/><path d="M20 12v16M12 20h16" stroke="#aeaeb3" stroke-width="2"/>',
  lock: '<rect x="8" y="17" width="24" height="18" rx="4" fill="#8e8e95"/><path d="M13 17v-5a7 7 0 0 1 14 0v5" fill="none" stroke="#8e8e95" stroke-width="4"/><circle cx="20" cy="26" r="2.5" fill="#ffffff"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5" fill="none" stroke="#8e8e95" stroke-width="2"/><path d="M16 16l5 5" stroke="#8e8e95" stroke-width="2" stroke-linecap="round"/>',
  plus: '<path d="M12 5v14M5 12h14" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round"/>',
  gear: '<g fill="none" stroke="#9c9ca3" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></g>',
};
const symbolViewBox = { vault: 40, lock: 40, search: 24, plus: 24, gear: 24 };
for (const [name, content] of Object.entries(symbolContent)) {
  const viewBox = symbolViewBox[name];
  svg = svg.replace(
    new RegExp(`<use href="#${name}" x="([\\d.]+)" y="([\\d.]+)" width="([\\d.]+)" height="([\\d.]+)"/>`, 'g'),
    (match, x, y, width) => {
      changes += 1;
      const scale = Number(width) / viewBox;
      return `<g transform="translate(${x} ${y}) scale(${Number(scale.toFixed(4))})">${content}</g>`;
    });
}

// ── 3. 头部区（画布 + 9 个主窗口）统一注入材质透明度 ─────────────────────────
// tokens 色板与附录区块不在头部，纯色样本保持不透明。
const tokensIndex = svg.indexOf('<g id="tokens"');
let head = svg.slice(0, tokensIndex);
let tail = svg.slice(tokensIndex);

const fillOpacity = new Map(Object.entries({
  '#1e1e22': '.74', // 弹窗类窗口底座
  '#232327': '.58', // 列表栏
  '#2a2a2f': '.62', // 详情栏
  '#2e2e34': '.58', // 标题栏 / 工具栏 / 卡片
  '#17171b': '.55', // 输入框（内凹）
  '#37373d': '.6',  // 次级按钮 / 选中行 / 圆形按钮
  '#3f3f46': '.6',  // 侧栏选中胶囊 / 列表图标底 / 大头像底
  '#3a3a41': '.55', // 1px 分隔矩形
  '#43434a': '.5',  // 进度轨道 / 待办圆点 / 强度条轨道
  '#48484f': '.65', // 开关关态轨道
}));
const strokeOpacity = new Map(Object.entries({
  '#3a3a41': '.6',  // 分隔线
  '#43434a': '.75', // 窗口外描边 / 进度轨道线
  '#48484f': '.8',  // 输入框描边 / 滑杆轨道
  '#4c4c53': '.8',  // 按钮描边
  '#515158': '.8',  // 复选框
  '#2a2a2f': '.62', // 详情头像徽章描边（与详情栏材质一致）
}));

for (const [hex, opacity] of fillOpacity) {
  // 负向断言：已带 fill-opacity 的不再命中，重复运行为无操作
  head = head.replace(new RegExp(`fill="${hex}"(?! fill-opacity)`, 'g'), `fill="${hex}" fill-opacity="${opacity}"`);
}
for (const [hex, opacity] of strokeOpacity) {
  head = head.replace(new RegExp(`stroke="${hex}"(?! stroke-opacity)`, 'g'), `stroke="${hex}" stroke-opacity="${opacity}"`);
}

// 偏好设置侧栏（唯一保留 #1a1a1e 的大面积材质）与滑杆图标实心旋钮
head = head.replace('<rect x="0" y="48" width="210" height="732" fill="#1a1a1e"/>',
  '<rect x="0" y="48" width="210" height="732" fill="#1a1a1e" fill-opacity=".5"/>');
head = head.replaceAll('<circle cx="9" cy="8" r="2.6" fill="#1a1a1e"/>', '<circle cx="9" cy="8" r="2.6" fill="#f5f5f7"/>');
head = head.replaceAll('<circle cx="15" cy="16" r="2.6" fill="#1a1a1e"/>', '<circle cx="15" cy="16" r="2.6" fill="#f5f5f7"/>');

// ── 4. 玻璃边缘：每个窗口底座追加 glassRim 内描边 ───────────────────────────
head = head.replace(
  /<rect width="(\d+)" height="(\d+)" rx="14" fill="[^"]+"(?: fill-opacity="[\d.]+")? stroke="#43434a" stroke-opacity="\.75"\/>(?!\s*<rect x="1" y="1")/g,
  (match, width, height) =>
    `${match}\n    <rect x="1" y="1" width="${Number(width) - 2}" height="${Number(height) - 2}" rx="13" fill="none" stroke="url(#glassRim)"/>`);

// ── 5. 细节校正：窗口标题基线统一（48px 标题栏，光学中心 = 交通灯中心 24）────
head = head.replaceAll('y="33" class="label" font-size="17" font-weight="600"', 'y="32" class="label" font-size="17" font-weight="600"');
head = head.replaceAll('y="34" class="label" font-size="17" font-weight="600"', 'y="32" class="label" font-size="17" font-weight="600"');

// 主窗口工具栏标题块：整体上移 3px，与工具栏图标（中心 83）光学对齐
head = head.replace('<text x="298" y="84" class="label title">全部项目</text>', '<text x="298" y="81" class="label title">全部项目</text>');
head = head.replace('<text x="298" y="104" class="subtle caption">24 个项目</text>', '<text x="298" y="101" class="subtle caption">24 个项目</text>');

// 偏好设置开关：垂直居中到「标题 + 说明」两行文本块（中心 ≈270，原 263）
for (const [from, to] of [['y="252"', 'y="259"'], ['y="336"', 'y="343"'], ['y="420"', 'y="427"'], ['y="504"', 'y="511"']]) {
  head = head.replace(`<rect x="842" ${from}`, `<rect x="842" ${to}`);
}
for (const [from, to] of [['cy="263"', 'cy="270"'], ['cy="347"', 'cy="354"'], ['cy="431"', 'cy="438"'], ['cy="515"', 'cy="522"']]) {
  head = head.replace(from, to);
}

// 编辑卡片字段标签：基线对齐输入框光学中心（中心 285）
for (const [label, from, to] of [['标题', '288', '291'], ['用户名', '356', '359'], ['密码', '424', '427'], ['网站', '492', '495']]) {
  head = head.replace(`<text x="78" y="${from}" class="muted small">${label}</text>`,
    `<text x="78" y="${to}" class="muted small">${label}</text>`);
}

// 详情页右缘统一为 64px 内边距（值列 1440 → 1458），圆形按钮随对齐
for (const y of ['427', '483', '539', '595', '651']) {
  head = head.replace(`x="1440" y="${y}"`, `x="1458" y="${y}"`);
}
head = head.replaceAll('x2="1440"', 'x2="1458"');
head = head.replace('x="1364" y="595"', 'x="1382" y="595"');
head = head.replace('transform="translate(1386 577) scale(0.75)"', 'transform="translate(1404 577) scale(0.75)"');
head = head.replace('<circle cx="1380" cy="807" r="19"', '<circle cx="1385" cy="807" r="19"');
head = head.replace('<circle cx="1434" cy="807" r="19"', '<circle cx="1439" cy="807" r="19"');
head = head.replace('transform="translate(1369 796) scale(0.92)"', 'transform="translate(1374 796) scale(0.92)"');
head = head.replace('transform="translate(1423 796) scale(0.92)"', 'transform="translate(1428 796) scale(0.92)"');

// 字重阶梯统一：大标题 700 → 600（与 26px 区块标题一致）
head = head.replace('<text x="1053" y="322" font-size="34" font-weight="700"', '<text x="1053" y="322" font-size="34" font-weight="600"');
head = head.replace('<text x="260" y="226" class="label" font-size="24" font-weight="700"', '<text x="260" y="226" class="label" font-size="24" font-weight="600"');

// ── 6. tokens 区：玻璃化面板 + 字体样本与标注一致（26/Semibold）──────────────
tail = tail.replace('<rect width="1200" height="470" rx="14" fill="#1e1e22" stroke="#43434a"/>',
`<rect width="1200" height="470" rx="14" fill="#1e1e22" fill-opacity=".74" stroke="#43434a" stroke-opacity=".75"/>
    <rect x="1" y="1" width="1198" height="468" rx="13" fill="none" stroke="url(#glassRim)"/>`);
tail = tail.replace('<text x="40" y="336" class="label" font-size="25" font-weight="700">Window Title · 26 / Semibold</text>',
  '<text x="40" y="336" class="label" font-size="26" font-weight="600">Window Title · 26 / Semibold</text>');
tail = tail.replace('Tokens · 设计语言 · Cupertino Native', 'Tokens · 设计语言 · Cupertino Glass');

svg = head + tail;

// ── 7. 设计系统更名 ─────────────────────────────────────────────────────────
replace('v1 · cupertino native system · editable vector source for Sketch',
  'v1 · cupertino glass system · frosted native materials · editable vector source for Sketch');

await writeFile(path, svg);
console.log(`Redesigned to Cupertino Glass: ${changes} token edits; materials, rims and alignment fixes applied.`);
