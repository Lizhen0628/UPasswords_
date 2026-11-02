// Chrome 弹窗设计稿配色升级：Flat Grey → Ink Aurora（2026-11-01）。
// 幂等：含标记注释时直接退出。迁移内容：
//  1. 全局色板重映射（深墨蓝底、精制蓝/紫渐变、高级状态色、墨灰描边）
//  2. 每个弹窗注入 popClip 裁剪的环境光晕（顶蓝底紫，内容之下、底色之上）
//  3. 主 CTA 顶部 1px 高光、品牌化 hero/品牌标光晕、底部导航改为悬浮胶囊
//  4. 弹窗外阴影加深、令牌区重写为新色板
import { readFile, writeFile } from 'node:fs/promises';

const svgPath = new URL('./UPasswords-chrome-all-ui.svg', import.meta.url);
let svg = await readFile(svgPath, 'utf8');

if (svg.includes('<!-- premium-ink applied -->')) {
  console.log('Ink Aurora already applied; no-op.');
  process.exit(0);
}

// ── 0. 画布氛围光晕增强（重映射前用旧色定位） ─────────────────────
svg = svg.replace('fill="#0a84ff" opacity=".16"', 'fill="#0a84ff" opacity=".22"');
svg = svg.replace('fill="#5e5ce6" opacity=".09"', 'fill="#5e5ce6" opacity=".13"');
svg = svg.replace('fill="#0a84ff" opacity=".08"', 'fill="#0a84ff" opacity=".10"');

// ── 1. 底部导航：扁平条 → 悬浮胶囊（旧色书写，随后由全局映射统一改色） ──
const legacyNav = `    <rect x="16" y="526" width="368" height="1" fill="#3a3a41"/>
    <rect y="527" width="400" height="73" fill="url(#navBg)"/>
    <rect x="26" y="535" width="80" height="40" rx="10" fill="#409cff" fill-opacity=".16"/>
    <rect x="58" y="541" width="12" height="10" rx="2.5" fill="none" stroke="#409cff" stroke-width="1.5"/>
    <path d="M60 541v-3a4 4 0 0 1 8 0v3" fill="none" stroke="#409cff" stroke-width="1.5"/>
    <text x="66" y="568" class="a" font-size="10" font-weight="600" text-anchor="middle">密码库</text>
    <rect x="194" y="538" width="13" height="13" rx="3" fill="none" stroke="#9c9ca3" stroke-width="1.5"/>
    <circle cx="197.5" cy="542" r=".9" fill="#9c9ca3"/><circle cx="203.5" cy="542" r=".9" fill="#9c9ca3"/>
    <circle cx="197.5" cy="547" r=".9" fill="#9c9ca3"/><circle cx="203.5" cy="547" r=".9" fill="#9c9ca3"/>
    <text x="200" y="568" class="s" font-size="10" text-anchor="middle">生成器</text>
    <circle cx="334" cy="544" r="6.5" fill="none" stroke="#9c9ca3" stroke-width="1.5"/>
    <circle cx="334" cy="544" r="2.2" fill="none" stroke="#9c9ca3" stroke-width="1.5"/>
    <text x="334" y="568" class="s" font-size="10" text-anchor="middle">设置</text>
    <text x="24" y="592" class="s" font-size="10.5">同步</text>
    <text x="376" y="592" class="err" font-size="10.5" text-anchor="end">退出登录</text>`;
const pillNav = `    <rect x="16" y="528" width="368" height="52" rx="26" fill="url(#navBg)" stroke="#3a3a41"/>
    <rect x="22" y="534" width="116" height="40" rx="20" fill="#409cff" fill-opacity=".16"/>
    <rect x="74" y="540" width="12" height="10" rx="2.5" fill="none" stroke="#409cff" stroke-width="1.5"/>
    <path d="M76 540v-3a4 4 0 0 1 8 0v3" fill="none" stroke="#409cff" stroke-width="1.5"/>
    <text x="80" y="568" class="a" font-size="10" font-weight="600" text-anchor="middle">密码库</text>
    <rect x="194" y="539" width="13" height="13" rx="3" fill="none" stroke="#9c9ca3" stroke-width="1.5"/>
    <circle cx="197.5" cy="543" r=".9" fill="#9c9ca3"/><circle cx="203.5" cy="543" r=".9" fill="#9c9ca3"/>
    <circle cx="197.5" cy="548" r=".9" fill="#9c9ca3"/><circle cx="203.5" cy="548" r=".9" fill="#9c9ca3"/>
    <text x="200" y="568" class="s" font-size="10" text-anchor="middle">生成器</text>
    <circle cx="320" cy="545" r="6.5" fill="none" stroke="#9c9ca3" stroke-width="1.5"/>
    <circle cx="320" cy="545" r="2.2" fill="none" stroke="#9c9ca3" stroke-width="1.5"/>
    <text x="320" y="568" class="s" font-size="10" text-anchor="middle">设置</text>
    <text x="28" y="596" class="s" font-size="10.5">同步</text>
    <text x="372" y="596" class="err" font-size="10.5" text-anchor="end">退出登录</text>`;
if (!svg.includes(legacyNav)) throw new Error('legacy nav block not found');
svg = svg.replace(legacyNav, pillNav);

// ── 2. 品牌/hero 光晕（新色直接书写，不参与映射） ──────────────────
const heroGlows = [
  // 01 登录（蓝）
  ['    <rect x="176" y="52" width="48" height="48" rx="14" fill="url(#cta)"/>',
   '    <ellipse cx="200" cy="76" rx="40" ry="26" fill="#2f6df2" opacity=".28" filter="url(#soft)"/>\n    <rect x="176" y="52" width="48" height="48" rx="14" fill="url(#cta)"/>'],
  // 02 连接密码库（紫）
  ['    <rect x="176" y="40" width="48" height="48" rx="14" fill="url(#av1)"/>',
   '    <ellipse cx="200" cy="64" rx="40" ry="26" fill="#6d5be2" opacity=".30" filter="url(#soft)"/>\n    <rect x="176" y="40" width="48" height="48" rx="14" fill="url(#av1)"/>'],
  // 03 解锁（蓝）
  ['    <rect x="176" y="72" width="48" height="48" rx="14" fill="url(#cta)"/>',
   '    <ellipse cx="200" cy="96" rx="40" ry="26" fill="#2f6df2" opacity=".28" filter="url(#soft)"/>\n    <rect x="176" y="72" width="48" height="48" rx="14" fill="url(#cta)"/>'],
  // 04 列表头部品牌标（小光晕）
  ['    <rect x="16" y="12" width="28" height="28" rx="8" fill="url(#cta)"/>',
   '    <ellipse cx="30" cy="26" rx="22" ry="16" fill="#2f6df2" opacity=".30" filter="url(#soft)"/>\n    <rect x="16" y="12" width="28" height="28" rx="8" fill="url(#cta)"/>'],
];
for (const [anchor, replacement] of heroGlows) {
  if (!svg.includes(anchor)) throw new Error(`hero anchor not found: ${anchor}`);
  svg = svg.replace(anchor, replacement);
}

// ── 3. 全局色板重映射（旧 → Ink Aurora） ──────────────────────────
// 先处理强调文本类（.a），再做全局替换，避免文本与填充混为一谈。
svg = svg.replace('.a { fill:#409cff; }', '.a { fill:#5ea6ff; }');

const palette = new Map(Object.entries({
  // 画布 / 弹窗底 / 材质
  '#1a1a1e': '#121218',   // 画布顶 & navBg 末
  '#101012': '#0c0c10',   // 画布底
  '#2a2a2f': '#191a20',   // 弹窗面起
  '#232327': '#14151b',   // 弹窗面止
  '#313138': '#23242c',   // 卡片起
  '#2e2e34': '#1e1f26',   // 卡片止
  '#1f1f23': '#15161c',   // 导航起
  '#17171b': '#0e0f13',   // 输入框
  '#1e1e22': '#16171d',   // 便签/状态底
  // 描边
  '#43434a': '#383944',
  '#48484f': '#3c3d47',
  '#3a3a41': '#2e2f39',
  '#4c4c53': '#434450',
  // 文本
  '#f5f5f7': '#f4f4f6',
  '#9c9ca3': '#a5a6af',
  '#6d6d74': '#71727c',
  '#aeaeb3': '#9a9ba5',
  '#8e8e95': '#8b8c96',
  // 品牌 / 强调（保留色相，加深提纯）
  '#409cff': '#4ea1ff',
  '#0a84ff': '#2f6df2',
  '#5e5ce6': '#6d5be2',
  // 状态色（更克制的高级色相）
  '#30d158': '#34d399',
  '#ffd60a': '#f6c453',
  '#ff453a': '#f87171',
  // 头像六色（去糖果感）
  '#bf5af2': '#8b7cf6',
  '#66d4cf': '#4fd1c5',
  '#30b0c7': '#2aa79b',
  '#ffb340': '#f7b955',
  '#ff9f0a': '#e08f2e',
  '#ff7eb6': '#f58aa8',
  '#ff375f': '#dd5f82',
  '#7ddb6e': '#5fd68f',
  '#64d2fc': '#5ec8f2',
}));
for (const [from, to] of palette) {
  svg = svg.split(from).join(to);
}

// ── 4. 弹窗外阴影加深 ────────────────────────────────────────────
svg = svg.replace(
  '<feDropShadow dx="0" dy="14" stdDeviation="24" flood-color="#000" flood-opacity="0.45"/>',
  '<feDropShadow dx="0" dy="18" stdDeviation="30" flood-color="#000" flood-opacity="0.55"/>',
);

// ── 5. 弹窗内环境光晕（popClip 裁剪，内容之下） ────────────────────
const clipDef = '    <clipPath id="popClip"><rect width="400" height="600" rx="14"/></clipPath>\n  </defs>';
if (!svg.includes('id="popClip"')) {
  if (!svg.includes('  </defs>')) throw new Error('defs close not found');
  svg = svg.replace('  </defs>', clipDef);
}
const rim = '<rect x="1" y="1" width="398" height="598" rx="13" fill="none" stroke="url(#glassRim)"/>';
const ambient = `${rim}
    <g id="ambientGlow" clip-path="url(#popClip)">
      <ellipse cx="120" cy="-50" rx="260" ry="130" fill="#2f6df2" opacity=".09" filter="url(#soft)"/>
      <ellipse cx="330" cy="560" rx="220" ry="140" fill="#6d5be2" opacity=".06" filter="url(#soft)"/>
    </g>`;
const rimCount = svg.split(rim).length - 1;
if (rimCount !== 12) throw new Error(`expected 12 popup rims, found ${rimCount}`);
svg = svg.split(rim).join(ambient);

// ── 6. 主 CTA 顶部 1px 高光 ──────────────────────────────────────
svg = svg.replace(
  /<rect x="24" y="(\d+)" width="352" height="(42|40|36)" rx="10" fill="url\(#cta\)"\/>/g,
  (match, y, height) => `${match}
    <rect x="25" y="${Number(y) + 1}" width="350" height="1" rx=".5" fill="#ffffff" opacity=".22"/>`,
);

// ── 7. 令牌区重写（Ink Aurora 色板） ──────────────────────────────
const tokensStart = svg.indexOf('  <g id="tokens"');
const tokensEnd = svg.indexOf('\n</svg>');
if (tokensStart < 0 || tokensEnd < 0) throw new Error('tokens group not found');
const tokens = `  <g id="tokens" transform="translate(1080 2260)">
    <text x="0" y="-28" class="screen">15 · 设计令牌 Design Tokens · Ink Aurora</text>
    <rect width="520" height="600" rx="14" fill="#16171d" stroke="#2e2f39"/>
    <text x="28" y="42" class="t" font-size="14" font-weight="700">颜色 · Ink Aurora 深墨色系</text>
    <rect x="28" y="58" width="40" height="40" rx="8" fill="#191a20" stroke="#383944"/><text x="76" y="75" class="s" font-size="10">surface</text><text x="76" y="90" class="w mono" font-size="10">#191a20→#14151b</text>
    <rect x="196" y="58" width="40" height="40" rx="8" fill="#23242c" stroke="#434450"/><text x="244" y="75" class="s" font-size="10">card / elevated</text><text x="244" y="90" class="w mono" font-size="10">#23242c→#1e1f26</text>
    <rect x="364" y="58" width="40" height="40" rx="8" fill="#0e0f13" stroke="#3c3d47"/><text x="412" y="75" class="s" font-size="10">input</text><text x="412" y="90" class="w mono" font-size="10">#0e0f13</text>
    <rect x="28" y="110" width="40" height="40" rx="8" fill="#15161c" stroke="#2e2f39"/><text x="76" y="127" class="s" font-size="10">nav / sidebar</text><text x="76" y="142" class="w mono" font-size="10">#15161c→#121218</text>
    <rect x="196" y="110" width="40" height="40" rx="8" fill="url(#cta)"/><text x="244" y="127" class="s" font-size="10">CTA / accent</text><text x="244" y="142" class="w mono" font-size="10">#4ea1ff→#2f6df2</text>
    <rect x="364" y="110" width="40" height="40" rx="8" fill="#16171d" stroke="#2e2f39"/><text x="412" y="127" class="s" font-size="10">border</text><text x="412" y="142" class="w mono" font-size="10">#2e2f39 / #3c3d47</text>
    <rect x="28" y="162" width="40" height="40" rx="8" fill="#f4f4f6"/><text x="76" y="179" class="s" font-size="10">text primary</text><text x="76" y="194" class="w mono" font-size="10">#f4f4f6</text>
    <rect x="196" y="162" width="40" height="40" rx="8" fill="#a5a6af"/><text x="244" y="179" class="s" font-size="10">text secondary</text><text x="244" y="194" class="w mono" font-size="10">#a5a6af / #71727c</text>
    <rect x="364" y="162" width="40" height="40" rx="8" fill="#34d399"/><text x="412" y="179" class="s" font-size="10">success</text><text x="412" y="194" class="w mono" font-size="10">#34d399</text>
    <rect x="28" y="214" width="40" height="40" rx="8" fill="#f6c453"/><text x="76" y="231" class="s" font-size="10">warning</text><text x="76" y="246" class="w mono" font-size="10">#f6c453</text>
    <rect x="196" y="214" width="40" height="40" rx="8" fill="#f87171"/><text x="244" y="231" class="s" font-size="10">danger</text><text x="244" y="246" class="w mono" font-size="10">#f87171</text>
    <rect x="364" y="214" width="40" height="40" rx="8" fill="url(#av1)"/><text x="412" y="231" class="s" font-size="10">avatar tints</text><text x="412" y="246" class="w mono" font-size="10">av0–av5 六色</text>
    <text x="28" y="292" class="t" font-size="14" font-weight="700">光晕与材质</text>
    <ellipse cx="52" cy="322" rx="24" ry="16" fill="#2f6df2" opacity=".30" filter="url(#soft)"/>
    <rect x="28" y="306" width="48" height="32" rx="9" fill="url(#cta)"/><text x="84" y="322" class="s" font-size="10">CTA 光晕 #2f6df2@28%</text>
    <rect x="28" y="346" width="48" height="32" rx="9" fill="url(#cardBg)" stroke="#434450"/>
    <rect x="29" y="347" width="46" height="1" rx=".5" fill="#ffffff" opacity=".22"/>
    <text x="84" y="362" class="s" font-size="10">顶部 1px 高光（白 @22%）</text>
    <rect x="28" y="386" width="48" height="32" rx="9" fill="url(#cardBg)" stroke="#2e2f39"/><text x="84" y="402" class="s" font-size="10">描边层次 #2e2f39→#434450</text>
    <text x="28" y="452" class="t" font-size="14" font-weight="700">字体阶梯（弹窗 1×）</text>
    <text x="28" y="480" class="t" font-size="18" font-weight="700">屏标题 18/700</text>
    <text x="220" y="480" class="t" font-size="16" font-weight="700">面板标题 16/700</text>
    <text x="380" y="480" class="t" font-size="13" font-weight="600">条目 13/600</text>
    <text x="28" y="506" class="t" font-size="12.5">正文 12.5/400</text>
    <text x="160" y="506" class="s" font-size="11">辅助 11/400</text>
    <text x="280" y="506" class="w" font-size="10.5" font-weight="600" letter-spacing=".5">分区标签 10.5/600</text>
    <text x="28" y="532" class="t mono" font-size="13" letter-spacing="2">等宽密码 mono 12.5–15</text>
    <text x="28" y="562" class="w" font-size="10.5">圆角：卡片 12 / 按钮 9–10 / 胶囊 999 · 网格 8px · 弹窗 360–440×≤600</text>
    <text x="28" y="580" class="w" font-size="10.5">环境光晕：顶 #2f6df2@9% 底 #6d5be2@6%（popClip 裁剪）· 阴影 dy18/blur30</text>
  </g>
  <!-- premium-ink applied -->`;
svg = svg.slice(0, tokensStart) + tokens + svg.slice(tokensEnd);

await writeFile(svgPath, svg);
console.log('Ink Aurora applied: palette remapped, ambient glows injected, nav pill, CTA highlights, tokens rewritten.');
