// 通用 Sketch 图层命名脚本：将 Sketch 导入 SVG 时生成的「编组」图层
// 重命名为有语义的名称。跨平台复用（macOS / Chrome / 未来平台）。
//
// 用法：
//   node name-sketch-layers.mjs <file.sketch> \
//     --page-name "页面名称" \
//     --canvas-title "画板标题文本" \
//     [--canvas-group-name "画布分组名"] \
//     [--special "标签A+标签B=分组名"] (可重复)
//
// 规则：
//  1. 分组含画板标题文本 → 画布分组（--canvas-group-name，默认"全部界面"）。
//  2. 分组内出现 "NN · 名称" 区块标签 → 用区块名称命名。
//  3. 命中 --special 规则（组内同时含全部 + 分隔标签）→ 指定名称。
//  4. 否则取组内第一个有意义文本（排除按钮等短词）命名；无文本则用对象 ID。
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error('Usage: node name-sketch-layers.mjs <file.sketch> --page-name <name> --canvas-title <title> [--canvas-group-name <name>] [--special "a+b=name"]');
  process.exit(1);
}

const sketchPath = resolve(args[0]);
const options = { specials: [] };
for (let index = 1; index < args.length; index += 1) {
  const value = args[index + 1];
  if (args[index] === '--page-name') { options.pageName = value; index += 1; }
  else if (args[index] === '--canvas-title') { options.canvasTitle = value; index += 1; }
  else if (args[index] === '--canvas-group-name') { options.canvasGroupName = value; index += 1; }
  else if (args[index] === '--root-name') { options.rootName = value; index += 1; }
  else if (args[index] === '--special') { options.specials.push(value); index += 1; }
}
if (!options.pageName || !options.canvasTitle) {
  console.error('Missing required --page-name or --canvas-title.');
  process.exit(1);
}

const canvasGroupName = options.canvasGroupName ?? '全部界面';
const specials = options.specials.map(rule => {
  const [labelsPart, name] = rule.split('=');
  return { labels: labelsPart.split('+'), name };
});

const workingDirectory = await mkdtemp(join(tmpdir(), 'upasswords-sketch-layers-'));

try {
  execFileSync('unzip', ['-q', sketchPath, '-d', workingDirectory]);
  const documentPath = join(workingDirectory, 'document.json');
  const document = JSON.parse(await readFile(documentPath, 'utf8'));
  let renamedCount = 0;

  for (const pageReference of document.pages) {
    const pagePath = join(workingDirectory, `${pageReference._ref}.json`);
    const page = JSON.parse(await readFile(pagePath, 'utf8'));
    page.name = options.pageName;

    function renameGenericGroups(layer) {
      for (const child of layer.layers ?? []) renameGenericGroups(child);
      if (layer._class !== 'group') return;
      // 「编组」为 Sketch 导入的无名分组；kebab-case 为保留下来的 SVG 分组 id。
      const isGeneric = layer.name === '编组';
      const isSvgId = /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.test(layer.name);
      if (!isGeneric && !isSvgId) return;

      const labels = [];
      function collectText(node) {
        if (node._class === 'text' && node.name) labels.push(node.name);
        for (const child of node.layers ?? []) collectText(child);
      }
      for (const child of layer.layers ?? []) collectText(child);

      // 画布判定仅限「编组」：SVG 根分组保留文件名（或用 --root-name 指定），
      // 不与画布分组重名。
      if (isGeneric && labels.includes(options.canvasTitle)) {
        layer.name = canvasGroupName;
        renamedCount += 1;
        return;
      }

      if (isSvgId && options.rootName && labels.includes(options.canvasTitle)) {
        layer.name = options.rootName;
        renamedCount += 1;
        return;
      }

      const sectionLabel = labels.find(label => /^\d{2} · /.test(label));
      if (sectionLabel) {
        layer.name = sectionLabel.replace(/^\d{2} · /, '');
        renamedCount += 1;
        return;
      }

      if (isSvgId) return; // 无区块标签的 SVG 分组保留原 id

      for (const rule of specials) {
        if (rule.labels.every(label => labels.includes(label))) {
          layer.name = rule.name;
          renamedCount += 1;
          return;
        }
      }

      const meaningfulLabel = labels.find(label => {
        const trimmed = label.trim();
        return trimmed.length > 1
          && !/^(取消|关闭|完成|保存|添加|继续|返回|恢复|应用|选择|解锁|导出|导入|复制|今天|昨天|打开|重试)$/.test(trimmed)
          && !/^([0-9]+|[⌘⌃⌥⇧]+)$/.test(trimmed);
      });

      if (meaningfulLabel) {
        layer.name = meaningfulLabel.length > 38
          ? `${meaningfulLabel.slice(0, 35)}...`
          : meaningfulLabel;
      } else {
        layer.name = `控件组 ${layer.do_objectID.slice(0, 8)}`;
      }
      renamedCount += 1;
    }

    for (const layer of page.layers ?? []) renameGenericGroups(layer);
    await writeFile(pagePath, JSON.stringify(page));
  }

  execFileSync('zip', ['-q', '-r', sketchPath, '.'], { cwd: workingDirectory });
  console.log(`Renamed ${renamedCount} generic Sketch groups in ${sketchPath}.`);
} finally {
  await rm(workingDirectory, { recursive: true, force: true });
}
