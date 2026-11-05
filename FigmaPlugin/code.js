// Turns capture JSON from the FigmaCapture Swift package into editable Figma layers.
figma.showUI(__html__, { width: 280, height: 170, themeColors: true });

figma.ui.onmessage = async (message) => {
  if (message.type !== 'import') return;
  try {
    const summary = await importCapture(message.capture);
    figma.ui.postMessage({ type: 'done', text: summary });
  } catch (error) {
    figma.ui.postMessage({ type: 'done', text: 'Import failed: ' + error.message });
  }
};

const counts = { text: 0, image: 0, vector: 0, frame: 0, stacks: 0 };
let textFont = { family: 'Inter', style: 'Regular' };
let usedFallback = false;
const paintStyles = new Map();

async function importCapture(capture) {
  Object.keys(counts).forEach((key) => { counts[key] = 0; });
  usedFallback = false;
  textFont = await chooseFont(capture.fontFamily);
  const existing = await figma.getLocalPaintStylesAsync();
  paintStyles.clear();
  existing.forEach((style) => paintStyles.set(style.name, style));

  const root = await build(capture.root, figma.currentPage);
  root.name = `${capture.app} screen`;
  // Next to whatever is already on the page.
  const others = figma.currentPage.children.filter((node) => node !== root);
  root.x = others.length ? Math.max(...others.map((node) => node.x + node.width)) + 80 : 0;
  root.y = others.length ? Math.min(...others.map((node) => node.y)) : 0;
  figma.currentPage.selection = [root];
  figma.viewport.scrollAndZoomIntoView([root]);

  const parts = `${counts.frame} frames, ${counts.text} texts, ${counts.vector} vectors, ${counts.image} images, ${counts.stacks} auto layouts.`;
  return usedFallback ? `${parts} Font "${capture.fontFamily}" isn't available in Figma, so text uses Inter.` : parts;
}

async function chooseFont(family) {
  const fallback = { family: 'Inter', style: 'Regular' };
  await figma.loadFontAsync(fallback);
  if (!family) return fallback;
  const fonts = await figma.listAvailableFontsAsync();
  const matches = fonts.filter((font) => font.fontName.family === family);
  if (!matches.length) {
    usedFallback = true;
    return fallback;
  }
  const chosen = (matches.find((font) => font.fontName.style === 'Regular') || matches[0]).fontName;
  await figma.loadFontAsync(chosen);
  return chosen;
}

function rgba(hex) {
  const value = (index) => parseInt(hex.slice(index, index + 2), 16) / 255;
  return { r: value(1), g: value(3), b: value(5), a: value(7) };
}

function solid(hex) {
  const { r, g, b, a } = rgba(hex);
  return { type: 'SOLID', color: { r, g, b }, opacity: a };
}

// Every colour becomes a shared style, so changing one recolours the whole screen.
async function applyFill(node, hex) {
  const name = `Capture/${hex.slice(1, 7)}${hex.slice(7) === 'FF' ? '' : ' ' + Math.round(rgba(hex).a * 100) + '%'}`;
  let style = paintStyles.get(name);
  if (!style) {
    style = figma.createPaintStyle();
    style.name = name;
    style.paints = [solid(hex)];
    paintStyles.set(name, style);
  }
  await node.setFillStyleIdAsync(style.id);
}

function gradientPaint(gradient, width, height) {
  const count = gradient.colors.length;
  const stops = gradient.colors.map((hex, index) => ({
    position: gradient.locations.length === count ? gradient.locations[index] : index / Math.max(1, count - 1),
    color: rgba(hex),
  }));
  // Figma's transform maps the shape's unit square onto the gradient's own line.
  const [x0, y0] = gradient.start;
  const [x1, y1] = gradient.end;
  const dx = (x1 - x0);
  const dy = (y1 - y0);
  const lengthSquared = dx * dx + dy * dy || 1;
  return {
    type: 'GRADIENT_LINEAR',
    gradientStops: stops,
    gradientTransform: [
      [dx / lengthSquared, dy / lengthSquared, -(x0 * dx + y0 * dy) / lengthSquared],
      [-dy / lengthSquared, dx / lengthSquared, (x0 * dy - y0 * dx) / lengthSquared],
    ],
  };
}

async function build(data, parent) {
  let node;
  if (data.kind === 'text') node = await buildText(data);
  else if (data.kind === 'vector') node = buildVector(data);
  else if (data.kind === 'image') node = buildImage(data);
  else node = await buildFrame(data);

  parent.appendChild(node);
  node.name = data.name;
  node.x = data.x;
  // A text box's height comes from the font, so it's centred on where the text was drawn.
  node.y = data.kind === 'text' ? data.y + (data.h - node.height) / 2 : data.y;
  if (data.opacity !== undefined) node.opacity = data.opacity;

  if (data.kind === 'rect' && data.children) {
    for (const child of data.children) await build(child, node);
    inferAutoLayout(node, data);
  }
  return node;
}

async function buildFrame(data) {
  counts.frame += 1;
  const frame = figma.createFrame();
  frame.resize(Math.max(data.w, 0.01), Math.max(data.h, 0.01));
  frame.fills = [];
  frame.clipsContent = data.name === 'Screen';
  if (data.fill) await applyFill(frame, data.fill);
  if (data.gradient) frame.fills = [gradientPaint(data.gradient, data.w, data.h)];
  if (data.corner) {
    frame.cornerRadius = data.corner;
    if (data.smooth) frame.cornerSmoothing = 0.6;
  }
  if (data.stroke) {
    frame.strokes = [solid(data.stroke)];
    frame.strokeWeight = data.strokeWidth;
    frame.strokeAlign = 'INSIDE';
  }
  const effects = [];
  if (data.blur) effects.push({ type: 'BACKGROUND_BLUR', radius: 20, visible: true });
  if (data.shadow) {
    effects.push({ type: 'DROP_SHADOW', color: rgba(data.shadow.color), offset: { x: data.shadow.x, y: data.shadow.y },
      radius: data.shadow.blur, spread: 0, visible: true, blendMode: 'NORMAL' });
  }
  if (effects.length) frame.effects = effects;
  return frame;
}

async function buildText(data) {
  counts.text += 1;
  const text = figma.createText();
  text.fontName = textFont;
  text.characters = data.text;
  text.fontSize = data.fontSize;
  if (data.fill) await applyFill(text, data.fill);
  text.textAutoResize = 'WIDTH_AND_HEIGHT';
  // The size was estimated from the drawn height. The drawn width settles it, when the app's own
  // font is here to measure with.
  if (!usedFallback && text.width > 0) {
    const longest = data.text.split('\n').length === 1;
    if (longest) text.fontSize = Math.max(1, Math.round((data.fontSize * data.w / text.width) * 2) / 2);
  }
  return text;
}

function buildVector(data) {
  counts.vector += 1;
  const rule = data.evenOdd ? ' fill-rule="evenodd"' : '';
  const { r, g, b, a } = rgba(data.fill);
  const color = `rgb(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)})`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${data.w}" height="${data.h}" viewBox="0 0 ${data.w} ${data.h}">`
    + `<path d="${data.path}" fill="${color}" fill-opacity="${a}"${rule}/></svg>`;
  return figma.createNodeFromSvg(svg);
}

function buildImage(data) {
  counts.image += 1;
  const rectangle = figma.createRectangle();
  rectangle.resize(Math.max(data.w, 0.01), Math.max(data.h, 0.01));
  if (data.corner) rectangle.cornerRadius = data.corner;
  if (data.png) {
    const image = figma.createImage(figma.base64Decode(data.png));
    rectangle.fills = [{ type: 'IMAGE', imageHash: image.hash, scaleMode: 'FILL' }];
  } else {
    rectangle.fills = [{ type: 'SOLID', color: { r: 0.2, g: 0.2, b: 0.2 } }];
  }
  return rectangle;
}

// A row or column of evenly spaced children becomes auto layout. Anything uneven stays as it is
// on screen, because a wrong guess would move things.
function inferAutoLayout(frame, data) {
  const kids = data.children;
  if (!kids || kids.length < 2 || data.name === 'Screen') return;
  const layout = stackOf(kids, 'x', 'w', 'y', 'h', data.w, data.h) || stackOf(kids, 'y', 'h', 'x', 'w', data.h, data.w);
  if (!layout) return;
  frame.layoutMode = layout.mainAxis === 'x' ? 'HORIZONTAL' : 'VERTICAL';
  frame.primaryAxisSizingMode = 'FIXED';
  frame.counterAxisSizingMode = 'FIXED';
  frame.resize(data.w, data.h);
  frame.itemSpacing = layout.gap;
  frame.primaryAxisAlignItems = 'MIN';
  frame.counterAxisAlignItems = layout.align;
  if (layout.mainAxis === 'x') {
    frame.paddingLeft = layout.before;
    frame.paddingTop = layout.cross;
    frame.paddingBottom = layout.align === 'CENTER' ? layout.cross : 0;
  } else {
    frame.paddingTop = layout.before;
    frame.paddingLeft = layout.cross;
    frame.paddingRight = layout.align === 'CENTER' ? layout.cross : 0;
  }
  counts.stacks += 1;
}

function stackOf(kids, main, mainSize, cross, crossSize, parentMain, parentCross) {
  const sorted = [...kids].sort((a, b) => a[main] - b[main]);
  if (sorted.some((kid, index) => kid !== kids[index])) return null;
  const gaps = sorted.slice(1).map((kid, index) => kid[main] - sorted[index][main] - sorted[index][mainSize]);
  if (gaps.some((gap) => gap < 0 || Math.abs(gap - gaps[0]) > 1)) return null;
  const lefts = kids.map((kid) => kid[cross]);
  const centres = kids.map((kid) => kid[cross] + kid[crossSize] / 2);
  const leftAligned = Math.max(...lefts) - Math.min(...lefts) <= 1;
  const centred = Math.abs(Math.max(...centres) - parentCross / 2) <= 1 && Math.abs(Math.min(...centres) - parentCross / 2) <= 1;
  if (!leftAligned && !centred) return null;
  return {
    mainAxis: main,
    gap: gaps[0],
    before: sorted[0][main],
    align: centred ? 'CENTER' : 'MIN',
    cross: centred ? 0 : Math.min(...lefts),
  };
}
