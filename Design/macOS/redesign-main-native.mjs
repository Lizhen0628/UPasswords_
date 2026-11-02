import { readFile, writeFile } from 'node:fs/promises';

// redesign-main-native.mjs — 2026-10-31 主窗口布局重构：参考 macOS 原生密码管理类应用的三栏样式。
// 齐平式侧栏（系统蓝高亮选中行）、扁平列表行（圆形钥匙图标 + 右侧日期/星标/警告三角）、
// 详情页居中大图标 + 左标签右值字段行 + 底部操作栏。幂等：以标记文本定位主窗口分组整体替换。

const path = new URL('./UPasswords-macOS-all-ui.svg', import.meta.url);
let svg = await readFile(path, 'utf8');

// ── 图标片段助手（24px 坐标系，使用处 transform 定位缩放）─────────────────
const keyIcon = (tx, ty, scale, color, width = 2) =>
  `<g fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round" transform="translate(${tx} ${ty}) scale(${scale})"><circle cx="15.5" cy="8.5" r="5"/><path d="M12 12l-7.5 7.5M7 16.5l2.5 2.5M9.5 14l2 2"/></g>`;
const starIcon = (tx, ty, scale, color, width = 1.8) =>
  `<g fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round" transform="translate(${tx} ${ty}) scale(${scale})"><path d="M12 3.5l2.5 5.1 5.6.8-4 4 .9 5.6-5-2.6-5 2.6.9-5.6-4-4 5.6-.8z"/></g>`;
const clockIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" transform="translate(${tx} ${ty}) scale(${scale})"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></g>`;
const shieldIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" transform="translate(${tx} ${ty}) scale(${scale})"><path d="M12 3l7.5 3v6c0 4.6-3 7.8-7.5 9-4.5-1.2-7.5-4.4-7.5-9V6z"/><path d="M12 9v4.5"/><circle cx="12" cy="16.5" r=".6" fill="${color}"/></g>`;
const gridIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" transform="translate(${tx} ${ty}) scale(${scale})"><rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/></g>`;
const tagIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round" transform="translate(${tx} ${ty}) scale(${scale})"><path d="M3.5 11.5V4.5H10.5L20 14l-6.5 6.5z"/><circle cx="7.5" cy="8.5" r="1.3" fill="${color}" stroke="none"/></g>`;
const trashIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" transform="translate(${tx} ${ty}) scale(${scale})"><path d="M4.5 6.5h15M9.5 6.5V4.5h5v2M6.5 6.5l1 13h9l1-13M10 10.5v6M14 10.5v6"/></g>`;
const lockIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" transform="translate(${tx} ${ty}) scale(${scale})"><rect x="5.5" y="10.5" width="13" height="9.5" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/></g>`;
const syncIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" transform="translate(${tx} ${ty}) scale(${scale})"><path d="M20 12a8 8 0 1 1-2.34-5.66M20 3.5V8h-4.5"/></g>`;
const shareIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" transform="translate(${tx} ${ty}) scale(${scale})"><path d="M12 15.5v-11M7.5 8.5L12 4l4.5 4.5M5.5 13.5v5a1.5 1.5 0 0 0 1.5 1.5h10a1.5 1.5 0 0 0 1.5-1.5v-5"/></g>`;
const copyIcon = (tx, ty, scale, color) =>
  `<g fill="none" stroke="${color}" stroke-width="2" transform="translate(${tx} ${ty}) scale(${scale})"><rect x="8.5" y="8.5" width="11" height="11" rx="2"/><path d="M15.5 8.5V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7.5a2 2 0 0 0 2 2h2.5"/></g>`;
const warnIcon = (tx, ty, scale) =>
  `<g transform="translate(${tx} ${ty}) scale(${scale})"><path d="M12 4L21.5 20.5H2.5z" fill="#ff453a"/><path d="M12 10v4.5" stroke="#ffffff" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="17.5" r="1.1" fill="#ffffff"/></g>`;

// ── 侧栏行 ────────────────────────────────────────────────────────────────
function sidebarRow(y, icon, label, count, { selected = false, accentCount = false } = {}) {
  const labelColor = selected ? '#409cff' : '#f5f5f7';
  const weight = selected ? 600 : 400;
  let out = '';
  if (selected) out += `<rect x="14" y="${y}" width="242" height="38" rx="9" fill="#3f3f46"/>`;
  out += icon(30, y + 10, 0.75, selected ? '#409cff' : '#9c9ca3');
  out += `<text x="58" y="${y + 25}" font-size="20" font-weight="${weight}" fill="${labelColor}" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${label}</text>`;
  out += `<text x="244" y="${y + 25}" font-size="16" fill="${accentCount ? '#ffd60a' : '#8e8e95'}" text-anchor="end" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${count}</text>`;
  return out;
}

// ── 列表行 ────────────────────────────────────────────────────────────────
const listRows = [
  { title: 'GitHub', sub: 'lizhen@workmail.com', date: '今天', mono: 'G', selected: true },
  { title: 'Apple ID', sub: 'lizhen@icloud.com', date: '昨天' },
  { title: '美国银行', sub: '•••• 4820', date: '10月 28日', warn: true },
  { title: 'Notion', sub: 'team@upasswords.dev', date: '10月 25日' },
  { title: 'Figma', sub: 'design@upasswords.dev', date: '10月 21日' },
];

function listRow(row, i) {
  const y = 164 + i * 74;
  let out = '<g>';
  if (row.selected) out += `<rect x="274" y="${y}" width="306" height="66" fill="#37373d"/>`;
  if (i > 0) out += `<line x1="338" y1="${y - 4}" x2="570" y2="${y - 4}" stroke="#3a3a41" stroke-width="1"/>`;
  if (row.mono) {
    out += `<circle cx="310" cy="${y + 33}" r="17" fill="url(#avatarGrad)"/>`;
    out += `<text x="310" y="${y + 40}" font-size="20" font-weight="600" fill="#ffffff" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${row.mono}</text>`;
  } else {
    out += `<circle cx="310" cy="${y + 33}" r="17" fill="#3f3f46"/>`;
    out += keyIcon(299, y + 22, 0.92, '#aeaeb3');
  }
  out += `<text x="338" y="${y + 30}" font-size="20" font-weight="600" fill="#f5f5f7" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${row.title}</text>`;
  if (row.warn) out += warnIcon(444, y + 15, 0.67);
  out += `<text x="338" y="${y + 55}" font-size="16" fill="#8e8e95" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${row.sub}</text>`;
  out += `<text x="570" y="${y + 27}" font-size="15" fill="#8e8e95" text-anchor="end" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${row.date}</text>`;
  out += starIcon(530, y + 40, 0.67, '#6d6d74');
  return out + '</g>';
}

// ── 详情字段行（左标签 / 右值）─────────────────────────────────────────────
function fieldRow(y, label, valueInner, { last = false } = {}) {
  let out = `<text x="648" y="${y + 35}" font-size="18" fill="#8e8e95" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">${label}</text>`;
  out += valueInner(y);
  if (!last) out += `<line x1="648" y1="${y + 56}" x2="1440" y2="${y + 56}" stroke="#3a3a41" stroke-width="1"/>`;
  return out;
}
const fieldValue = (text, color = '#ebebf0', extra = '') => y =>
  `<text x="1440" y="${y + 35}" font-size="18" fill="${color}" text-anchor="end" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif"${extra}>${text}</text>`;

const mainWindow = `  <!-- MAIN WINDOW -->
  <g id="main-window" transform="translate(120 160)" filter="url(#shadow)">
    <text x="0" y="-28" class="screen-name">01 · 主密码库 / Main Vault</text>
    <rect width="1540" height="900" rx="14" fill="url(#window)" stroke="#43434a"/>
    <clipPath id="mainClip"><rect width="1540" height="900" rx="14"/></clipPath>
    <g clip-path="url(#mainClip)">
      <rect x="0" y="48" width="270" height="852" fill="url(#sidebar)"/>
      <rect x="270" y="118" width="314" height="782" fill="#232327"/>
      <rect x="584" y="118" width="938" height="764" fill="#2a2a2f"/>
      <rect width="1540" height="48" fill="#2e2e34"/>
      <rect x="270" y="48" width="1252" height="70" fill="#2e2e34"/>
    </g>
    <line x1="0" y1="48" x2="1540" y2="48" stroke="#3a3a41" stroke-width="1"/>
    <line x1="270" y1="48" x2="270" y2="900" stroke="#3a3a41" stroke-width="1"/>
    <line x1="270" y1="118" x2="1522" y2="118" stroke="#3a3a41" stroke-width="1"/>
    <line x1="584" y1="118" x2="584" y2="900" stroke="#3a3a41" stroke-width="1"/>
    <circle cx="24" cy="24" r="7" fill="#ff5f57"/><circle cx="48" cy="24" r="7" fill="#febc2e"/><circle cx="72" cy="24" r="7" fill="#28c840"/>
    <g fill="none" stroke="#9c9ca3" stroke-width="1.8" transform="translate(230 13)"><rect x="3" y="4.5" width="18" height="15" rx="3.5"/><line x1="9.5" y1="4.5" x2="9.5" y2="19.5"/></g>

    <text x="26" y="88" class="subtle section">main</text>
    ${sidebarRow(100, gridIcon, '全部项目', '24', { selected: true })}
    ${sidebarRow(138, starIcon, '收藏', '8')}
    ${sidebarRow(176, clockIcon, '最近使用', '12')}
    ${sidebarRow(214, shieldIcon, '安全检查', '3', { accentCount: true })}
    <text x="26" y="286" class="subtle section">标签</text>
    ${sidebarRow(296, tagIcon, '工作', '14')}
    ${sidebarRow(332, tagIcon, '个人', '10')}
    ${sidebarRow(368, tagIcon, '财务', '5')}
    <text x="26" y="428" class="subtle section">数据库</text>
    <use href="#vault" x="28" y="438" width="22" height="22"/><text x="58" y="455" class="label body">Personal Vault</text>
    <circle cx="30" cy="816" r="4" fill="#30d158"/><text x="44" y="822" class="muted small">同步于 2 分钟前</text><text x="26" y="856" class="subtle small">显示 · 计数</text>

    <text x="298" y="84" class="label title">全部项目</text><text x="298" y="104" class="subtle caption">24 个项目</text>
    ${keyIcon(920, 71, 1, '#9c9ca3', 1.8)}
    ${syncIcon(964, 71, 1, '#9c9ca3')}
    ${trashIcon(1008, 71, 1, '#9c9ca3')}
    ${lockIcon(1052, 71, 1, '#9c9ca3')}
    <use href="#gear" x="1096" y="71" width="24" height="24"/>
    <rect x="1148" y="67" width="200" height="32" rx="16" fill="#17171b" stroke="#48484f"/>
    <use href="#search" x="1160" y="73" width="20" height="20"/><text x="1188" y="88" class="subtle small">搜索项目</text>
    <rect x="1364" y="67" width="38" height="32" rx="9" fill="url(#whiteBtn)"/><use href="#plus" x="1371" y="71" width="24" height="24"/>
    <rect x="1424" y="67" width="38" height="32" rx="9" fill="#37373d" stroke="#4c4c53"/>
    <g fill="#ebebf0"><circle cx="1437" cy="83" r="2"/><circle cx="1443" cy="83" r="2"/><circle cx="1449" cy="83" r="2"/></g>

    <text x="294" y="150" class="subtle caption">项目</text>
    ${listRows.map(listRow).join('\n    ')}

    <circle cx="1053" cy="206" r="48" fill="#3f3f46"/>
    ${keyIcon(1025, 178, 2.33, '#ebebf0')}
    <circle cx="1090" cy="242" r="15" fill="#515158" stroke="#2a2a2f" stroke-width="3"/>
    <g fill="#ebebf0" transform="translate(1082 234) scale(0.67)"><circle cx="12" cy="8" r="4.2"/><path d="M4 20c0-4.4 3.6-8 8-8s8 3.6 8 8z"/></g>
    <text x="1053" y="322" font-size="34" font-weight="700" fill="#f5f5f7" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">GitHub</text>
    <text x="1053" y="350" font-size="16" fill="#8e8e95" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">工作 · 开发工具</text>

    ${fieldRow(392, '登录', fieldValue('lizhen@workmail.com'))}
    ${fieldRow(448, '密码', fieldValue('••••••••••••', '#8e8e95', ' class="mono"'))}
    ${fieldRow(504, '网址', fieldValue('https://github.com', '#409cff'))}
    ${fieldRow(560, '一次性验证码', y =>
      `<text x="1364" y="${y + 35}" font-size="20" font-weight="600" fill="#409cff" text-anchor="end" class="mono">348 291</text>` +
      copyIcon(1386, y + 17, 0.75, '#8e8e95') +
      `<text x="1440" y="${y + 35}" font-size="15" fill="#6d6d74" text-anchor="end" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">(24s)</text>`)}
    ${fieldRow(616, '备注', fieldValue('团队仓库与发布权限。', '#8e8e95'), { last: true })}

    <rect x="648" y="788" width="104" height="38" rx="9" fill="#37373d" stroke="#4c4c53"/><text x="700" y="812" font-size="20" fill="#ebebf0" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">编辑</text>
    <rect x="764" y="788" width="130" height="38" rx="9" fill="#37373d" stroke="#4c4c53"/><text x="829" y="812" font-size="20" fill="#ebebf0" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">设置标签</text>
    <rect x="930" y="798" width="18" height="18" rx="4.5" fill="none" stroke="#515158" stroke-width="1.5"/><text x="958" y="812" font-size="16" fill="#8e8e95" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">用于自动填充</text>
    <circle cx="1380" cy="807" r="19" fill="#37373d" stroke="#4c4c53"/>${starIcon(1369, 796, 0.92, '#9c9ca3')}
    <circle cx="1434" cy="807" r="19" fill="#37373d" stroke="#4c4c53"/>${shareIcon(1423, 796, 0.92, '#9c9ca3')}
  </g>
`;

// ── 整体替换主窗口分组（从注释标记到 LOCK 注释之前）─────────────────────────
const pattern = /  <!-- MAIN WINDOW -->[\s\S]*?(?=  <!-- LOCK -->)/;
if (!pattern.test(svg)) throw new Error('main window group not found');
svg = svg.replace(pattern, `${mainWindow}\n`);

// ── 侧栏渐变压暗（齐平式侧栏为全窗最深区域）────────────────────────────────
svg = svg.replace(
  '<linearGradient id="sidebar" x1="0" y1="0" x2="0" y2="1">\n      <stop offset="0" stop-color="#232327"/>\n      <stop offset="1" stop-color="#1f1f23"/>\n    </linearGradient>',
  '<linearGradient id="sidebar" x1="0" y1="0" x2="0" y2="1">\n      <stop offset="0" stop-color="#1f1f23"/>\n      <stop offset="1" stop-color="#1a1a1e"/>\n    </linearGradient>');

await writeFile(path, svg);
console.log('Main window rebuilt in native three-column style.');
