// 通用浅色主题生成：对暗色 .sketch 做 Cupertino 系统调色板重映射。
// 跨平台复用（macOS / Chrome / 未来平台）。
//
// 用法：
//   node create-light-theme.mjs <dark.sketch> <light.sketch> \
//     --page-name "页面名称" \
//     [--canvas-group "暗色画布分组名"] [--canvas-group-light "浅色画布分组名"] \
//     [--board-group "暗色画板分组名"] [--board-group-light "浅色画板分组名"] \
//     [--title "浅色画板标题"] [--subtitle "浅色画板副标题"]
//
// 画布/画板分组名与标题参数均为可选：提供时同步重命名图层与前两条文本。
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const args = process.argv.slice(2);
if (args.length < 2) {
  console.error('Usage: node create-light-theme.mjs <dark.sketch> <light.sketch> --page-name <name> [options]');
  process.exit(1);
}

const [sourcePath, outputPath] = [resolve(args[0]), resolve(args[1])];
const options = {};
for (let index = 2; index < args.length; index += 1) {
  if (!args[index].startsWith('--')) continue;
  options[args[index].slice(2)] = args[index + 1];
  index += 1;
}
if (!options['page-name']) {
  console.error('Missing required --page-name.');
  process.exit(1);
}

const workingDirectory = await mkdtemp(join(tmpdir(), 'upasswords-light-theme-'));

// Cupertino 暗色 → 浅色映射（Apple 浅色灰阶 + 系统蓝 #007aff）。
const palette = new Map(Object.entries({
  // Canvas / window chrome（中性深灰 → Apple 浅色灰阶）
  '#101012': '#e8e8ed',
  '#131316': '#efeff3',
  '#16181f': '#e9ebf1',
  '#17171b': '#f8f8fa',
  '#1a1a1e': '#ebebf0',
  '#1d2029': '#e5e7ee',
  '#1e1e22': '#f4f4f6',
  '#1f1f23': '#e6e6eb',
  '#232327': '#e3e3e8',
  '#26262b': '#ffffff',
  '#2a2a2f': '#ffffff',
  '#2a2a30': '#fafafc',
  '#2e2e34': '#f6f6f8',
  '#313138': '#ffffff',
  '#37373d': '#ffffff',
  // 选中 / 分隔线 / 边框
  '#3f3f46': '#e2e2e7',
  '#3a3a41': '#d9d9de',
  '#43434a': '#d1d1d6',
  '#48484f': '#c7c7cc',
  '#4c4c53': '#bfbfc4',
  '#515158': '#b2b2b8',
  '#5c5c63': '#aeaeb3',
  // Text / foreground (inverted)
  '#f5f5f7': '#1d1d1f',
  '#ebebf0': '#2c2c30',
  '#d5d5db': '#3a3a3f',
  '#aeaeb3': '#55555b',
  '#9c9ca3': '#6e6e74',
  '#8e8e95': '#7d7d83',
  '#7a7a81': '#8e8e94',
  '#6d6d74': '#9a9aa0',
  // CTA / 开关 / 头像上的白色文字保持白色
  '#ffffff': '#ffffff',
  // Accent / gradient stops / glows → 浅色主题系统蓝
  '#409cff': '#2f8fff',
  '#0a84ff': '#007aff',
  '#5e5ce6': '#5e5ce6',
  // Status → Apple 系统色（浅色）
  '#30d158': '#28cd41',
  '#ffd60a': '#ffcc00',
  '#ff453a': '#ff3b30',
  // Label dot pastels → Apple 系统色（浅色）
  '#64d2fc': '#32ade6',
  '#bf5af2': '#af52de',
  // ── Ink Aurora（Chrome 弹窗 2026-11-01）→ 浅色灰阶与精制色相 ──
  '#121218': '#ececf0',
  '#0c0c10': '#e6e6eb',
  '#191a20': '#ffffff',
  '#14151b': '#eaeaef',
  '#15161c': '#f2f2f5',
  '#101116': '#e3e3e8',
  '#23242c': '#ffffff',
  '#1e1f26': '#f7f7f9',
  '#16171d': '#f4f4f6',
  '#0e0f13': '#f8f8fa',
  '#2e2f39': '#dcdce1',
  '#33343e': '#d1d1d6',
  '#383944': '#c7c7cc',
  '#3c3d47': '#c9c9cf',
  '#434450': '#bfbfc4',
  '#464752': '#b5b5bb',
  '#f4f4f6': '#1d1d1f',
  '#a5a6af': '#6a6a70',
  '#71727c': '#9a9aa0',
  '#9a9ba5': '#55555b',
  '#8b8c96': '#7d7d83',
  '#4ea1ff': '#2f8fff',
  '#2f6df2': '#0057e7',
  '#5ea6ff': '#0066d6',
  '#34d399': '#1e9e6f',
  '#f6c453': '#d97706',
  '#f87171': '#dc4446',
  '#8b7cf6': '#7a68e8',
  '#6d5be2': '#5e4fd6',
  '#4fd1c5': '#25b3a6',
  '#2aa79b': '#1f8a80',
  '#f7b955': '#e8940f',
  '#e08f2e': '#c1761a',
  '#f58aa8': '#e0607f',
  '#dd5f82': '#c94a6c',
  '#5fd68f': '#3cb371',
  '#5ec8f2': '#32ade6',
}));

function colorHex(color) {
  const channel = value => Math.round(value * 255).toString(16).padStart(2, '0');
  return `#${channel(color.red)}${channel(color.green)}${channel(color.blue)}`.toLowerCase();
}

function mapColors(value, counts) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      value[index] = mapColors(value[index], counts);
    }
    return value;
  }
  if (!value || typeof value !== 'object') return value;

  if (value._class === 'color') {
    const original = colorHex(value);
    const replacement = palette.get(original);
    if (replacement) {
      const hex = replacement.slice(1);
      value.red = Number.parseInt(hex.slice(0, 2), 16) / 255;
      value.green = Number.parseInt(hex.slice(2, 4), 16) / 255;
      value.blue = Number.parseInt(hex.slice(4, 6), 16) / 255;
      counts.set(original, (counts.get(original) ?? 0) + 1);
    }
  }

  for (const [key, child] of Object.entries(value)) {
    value[key] = mapColors(child, counts);
  }
  return value;
}

function setText(layer, value) {
  layer.name = value;
  layer.attributedString.string = value;
}

try {
  execFileSync('unzip', ['-q', sourcePath, '-d', workingDirectory]);
  const documentPath = join(workingDirectory, 'document.json');
  const document = JSON.parse(await readFile(documentPath, 'utf8'));
  const pageReference = document.pages[0];
  const pagePath = join(workingDirectory, `${pageReference._ref}.json`);
  const page = JSON.parse(await readFile(pagePath, 'utf8'));
  const mappedColors = new Map();
  mapColors(page, mappedColors);

  page.name = options['page-name'];
  for (const layer of page.layers ?? []) {
    if (layer._class !== 'group') continue;
    if (options['canvas-group'] && layer.name === options['canvas-group']) {
      layer.name = options['canvas-group-light'] ?? layer.name;
      const background = layer.layers?.find(item => item._class === 'rectangle');
      if (background) background.frame.height = layer.frame.height;
    }
    for (const child of layer.layers ?? []) {
      if (child._class !== 'group') continue;
      if (options['board-group'] && child.name === options['board-group']) {
        child.name = options['board-group-light'] ?? child.name;
        const metadata = (child.layers ?? []).filter(item => item._class === 'text');
        if (options.title && metadata[0]) setText(metadata[0], options.title);
        if (options.subtitle && metadata[1]) setText(metadata[1], options.subtitle);
      }
    }
  }

  await writeFile(pagePath, JSON.stringify(page));
  await rm(outputPath, { force: true }); // zip -r 不会剔除旧条目，先删除再打包
  execFileSync('zip', ['-q', '-r', outputPath, '.'], { cwd: workingDirectory });
  console.log(`Created ${outputPath}; remapped ${[...mappedColors.values()].reduce((sum, count) => sum + count, 0)} color values.`);
} finally {
  await rm(workingDirectory, { recursive: true, force: true });
}
