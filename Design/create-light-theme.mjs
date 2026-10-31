import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sourcePath = new URL('./UPasswords-macOS-All-UI.sketch', import.meta.url);
const outputPath = new URL('./UPasswords-macOS-All-UI-Light.sketch', import.meta.url);
const workingDirectory = await mkdtemp(join(tmpdir(), 'upasswords-light-theme-'));

// Cupertino Native 暗色 → 浅色映射。键与 refine-cupertino.mjs 产出的暗色值一一对应。
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
  // CTA / 开关 / 头像上的白色文字保持白色（按钮本体为系统蓝渐变，见下）
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

try {
  execFileSync('unzip', ['-q', sourcePath.pathname, '-d', workingDirectory]);
  const documentPath = join(workingDirectory, 'document.json');
  const document = JSON.parse(await readFile(documentPath, 'utf8'));
  const pageReference = document.pages[0];
  const pagePath = join(workingDirectory, `${pageReference._ref}.json`);
  const page = JSON.parse(await readFile(pagePath, 'utf8'));
  const mappedColors = new Map();
  mapColors(page, mappedColors);

  page.name = 'macOS 浅色主题 · 全部 UI';
  for (const layer of page.layers ?? []) {
    if (layer._class !== 'group') continue;
    if (layer.name === 'UPasswords macOS 全部界面画布') {
      layer.name = 'UPasswords macOS 浅色主题画布';
      const background = layer.layers?.find(item => item._class === 'rectangle');
      if (background) background.frame.height = layer.frame.height;
    }
    for (const child of layer.layers ?? []) {
      if (child._class !== 'group' || child.name !== 'UPasswords macOS UI 全部界面') continue;
      child.name = 'UPasswords macOS 浅色主题 · 全部界面';
      const metadata = (child.layers ?? []).filter(item => item._class === 'text');
      if (metadata[0]) {
        metadata[0].name = 'UPasswords · macOS Light UI';
        metadata[0].attributedString.string = metadata[0].name;
      }
      if (metadata[1]) {
        metadata[1].name = 'v1 · light appearance · editable vector source for Sketch';
        metadata[1].attributedString.string = metadata[1].name;
      }
    }
  }

  await writeFile(pagePath, JSON.stringify(page));
  await rm(outputPath.pathname, { force: true }); // zip -r 不会剔除旧条目，先删除再打包
  execFileSync('zip', ['-q', '-r', outputPath.pathname, '.'], { cwd: workingDirectory });
  console.log(`Created ${outputPath.pathname}; remapped ${[...mappedColors.values()].reduce((sum, count) => sum + count, 0)} color values.`);
} finally {
  await rm(workingDirectory, { recursive: true, force: true });
}
