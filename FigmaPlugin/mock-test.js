// Runs the plugin against a stand-in for Figma's API: node mock-test.js capture.json
const fs = require('fs');
const vm = require('vm');
const capture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let handler;
const posted = [];
const page = { children: [], appendChild(n) { n.parent = this; this.children.push(n); }, selection: [] };
function nodeBase(type) {
  return { type, x: 0, y: 0, width: 100, height: 20, children: [], fills: [], opacity: 1,
    appendChild(n) { n.parent = this; this.children.push(n); },
    resize(w, h) { this.width = w; this.height = h; },
    async setFillStyleIdAsync(id) { if (!id) throw new Error('no style id'); this.fillStyleId = id; } };
}
const figma = {
  showUI() {}, ui: { set onmessage(f) { handler = f; }, postMessage: (m) => posted.push(m) },
  currentPage: page, viewport: { scrollAndZoomIntoView() {} },
  getLocalPaintStylesAsync: async () => [],
  createPaintStyle: () => ({ id: 'S' + Math.random() }),
  loadFontAsync: async () => {},
  listAvailableFontsAsync: async () => [{ fontName: { family: 'FA-1', style: 'Regular' } }],
  createFrame: () => nodeBase('FRAME'),
  createRectangle: () => nodeBase('RECTANGLE'),
  createText: () => { const t = nodeBase('TEXT'); t.height = 12; let size = 12;
    Object.defineProperty(t, 'fontSize', { get: () => size, set: (v) => { if (!(v > 0)) throw new Error('bad size'); size = v; } }); return t; },
  createNodeFromSvg: (svg) => { if (!svg.includes('d="M')) throw new Error('bad svg ' + svg.slice(0, 80)); return nodeBase('FRAME'); },
  createImage: (bytes) => ({ hash: 'h' + bytes.length }),
  base64Decode: (s) => Buffer.from(s, 'base64'),
};
vm.runInNewContext(fs.readFileSync(__dirname + '/code.js', 'utf8'), { figma, __html__: '', Math, console, parseInt, Map, Object });
handler({ type: 'import', capture }).then(() => {
  console.log(posted.at(-1).text);
  const show = (n, d = 0) => {
    if (n.type !== 'TEXT' && n.layoutMode) console.log(' '.repeat(d) + n.name, n.layoutMode, 'gap', n.itemSpacing, 'pad', n.paddingLeft, n.paddingTop, n.counterAxisAlignItems);
    n.children.forEach((c) => show(c, d + 1));
  };
  page.children.forEach((n) => show(n));
  if (posted.at(-1).text.startsWith('Import failed')) process.exit(1);
});
