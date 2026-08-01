#!/usr/bin/env node
/**
 * visual-hierarchy-linter.mjs — Static CSS analysis for carousel slides
 *
 * Checks:
 *   P0: contrast ratio, font-size minimums, typography count
 *   P1: safe zone violations, spacing consistency
 *   P2: emphasis color area, raw hex values
 *
 * Usage: node linter.mjs <file.html>
 *        node linter.mjs --demo
 *        node linter.mjs <file.html> --json
 *
 * Escape hatches: CSS comment /* linter-ignore: <check-name> *​/
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ═══════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════



// ═══════════════ TOKEN LOADING ═══════════════
// ponytail: read tokens.json at init so linter stays in sync with single source of truth
function loadTokens() {
  const tokPath = path.resolve(__dirname, './tokens.json');
  try { return JSON.parse(fs.readFileSync(tokPath, 'utf8')); }
  catch { return null; }
}
const _tok = loadTokens();
const TOKEN_HEXES = new Set(_tok
  ? Object.values(_tok).filter(v => typeof v === 'string' && v.startsWith('#'))
  : ['#5b3b8c', '#3f2766', '#34204f', '#f2c94c', '#ffffff', '#efe9dc', '#c9bbe0']);
// Load safe zones from tokens.json (canonical source)
const _sz = _tok?.safeZones || null;

// ═══ Design constants (canonical: tokens.json) ═══
const CANVAS = _sz?.canvas || { w: 1080, h: 1080 };
const SAFE_ZONE = _sz?.universal || { xMin: 35, xMax: 1045, yMin: 135, yMax: 945 };
const UI_OVERLAY_BOTTOM = _sz?.uiOverlay?.bottom ?? 150;
const UI_OVERLAY_TOP = _sz?.uiOverlay?.top ?? 120;
const MIN_BODY_PX = _tok?.typography?.minBodyPx ?? 20;
const MAX_FONT_FAMILIES = _tok?.typography?.maxFamilies ?? 2;
const MAX_FONT_SIZES = _tok?.typography?.maxSizesPerSlide ?? 3;
const MIN_CONTRAST = 4.5;
const WCAG_AA_LARGE = 3.0;
const MAX_YELLOW_PCT = _tok?.typography?.maxYellowPercent ?? 10;

const SAFE_RAW_HEXES = new Set([
  '#1a1a1a', '#000', '#000000', '#fff',
]);

// ═══════════════════════════════════════════════════════════════
// COLOR UTILITIES — WCAG 2.2
// ═══════════════════════════════════════════════════════════════

function hexToRgb(hex) {
  hex = hex.replace('#', '');
  if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
  if (hex.length === 8) hex = hex.slice(0, 6);
  if (hex.length !== 6) return null;
  return {
    r: parseInt(hex.slice(0, 2), 16),
    g: parseInt(hex.slice(2, 4), 16),
    b: parseInt(hex.slice(4, 6), 16),
  };
}

function parseColor(str) {
  if (!str) return null;
  str = str.trim().toLowerCase();
  if (/^#[0-9a-f]{3,8}$/.test(str)) return hexToRgb(str);
  const m = str.match(/rgba?\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
  if (m) return { r: +m[1], g: +m[2], b: +m[3] };
  const named = { white: [255,255,255], black: [0,0,0] };
  if (named[str]) { const [r,g,b] = named[str]; return { r, g, b }; }
  return null;
}

function linearize(c) {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
}

function relativeLuminance(rgb) {
  if (!rgb) return null;
  return 0.2126 * linearize(rgb.r) + 0.7152 * linearize(rgb.g) + 0.0722 * linearize(rgb.b);
}

function contrastRatio(c1, c2) {
  if (!c1 || !c2) return null;
  const l1 = relativeLuminance(c1);
  const l2 = relativeLuminance(c2);
  if (l1 === null || l2 === null) return null;
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

// ═══════════════════════════════════════════════════════════════
// CSS PARSER
// ═══════════════════════════════════════════════════════════════

function stripComments(css) {
  return css.replace(/\/\*[\s\S]*?\*\//g, '');
}

function parseCSS(cssText) {
  const rules = [];
  const rootVars = {};
  const clean = stripComments(cssText);

  const rootMatch = clean.match(/:root\s*\{([^}]+)\}/);
  if (rootMatch) {
    for (const m of rootMatch[1].matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
      rootVars[m[1].trim()] = m[2].trim();
    }
  }

  const blockRe = /([^{}]+)\{([^{}]+)\}/g;
  let blockMatch;
  while ((blockMatch = blockRe.exec(clean)) !== null) {
    const selector = blockMatch[1].trim();
    if (selector.startsWith('@') || selector.startsWith(':')) continue;
    const body = blockMatch[2];
    const props = {};
    for (const pm of body.matchAll(/([\w-]+)\s*:\s*([^;]+);/g)) {
      props[pm[1].trim()] = pm[2].trim();
    }
    rules.push({ selector, props });
  }
  return { rules, rootVars };
}

function resolveVar(value, rootVars) {
  if (!value) return value;
  return value.replace(/var\((--[\w-]+)\)/g, (_, name) => rootVars[name] || _);
}

function findMatchingRules(elClasses, cssRules) {
  const matches = [];
  for (const rule of cssRules) {
    const parts = rule.selector.split(/\s+/);
    const lastPart = parts[parts.length - 1];
    if (lastPart.startsWith('.')) {
      const cls = lastPart.slice(1);
      if (elClasses.includes(cls)) {
        matches.push({ ...rule, specificity: parts.length * 10 });
      }
    }
    if (/^[a-z]+$/.test(lastPart)) {
      if (elClasses.includes('__tag__' + lastPart)) {
        matches.push({ ...rule, specificity: 1 });
      }
    }
  }
  matches.sort((a, b) => b.specificity - a.specificity);
  return matches;
}

// ═══════════════════════════════════════════════════════════════
// HTML PARSER
// ═══════════════════════════════════════════════════════════════

function parseSlides(html) {
  const slideRe = /<div\s+class="slide\s+([^"]*)"[^>]*>/g;
  const slides = [];
  let match;
  while ((match = slideRe.exec(html)) !== null) {
    const classes = match[1].split(/\s+/);
    const start = match.index + match[0].length;
    let depth = 1;
    let pos = start;
    const openRe = /<div[\s>]/g;
    const closeRe = /<\/div>/g;
    while (depth > 0 && pos < html.length) {
      openRe.lastIndex = pos;
      closeRe.lastIndex = pos;
      const nextOpen = openRe.exec(html);
      const nextClose = closeRe.exec(html);
      if (!nextClose) break;
      const openIdx = nextOpen ? nextOpen.index : Infinity;
      const closeIdx = nextClose.index;
      if (openIdx < closeIdx) {
        depth++;
        pos = openIdx + 4;
      } else {
        depth--;
        pos = closeIdx + 6;
      }
    }
    const slideHtml = html.substring(match.index, pos);
    slides.push({ index: slides.length + 1, classes, html: slideHtml });
  }
  return slides;
}

function extractTextElements(slideHtml) {
  const elements = [];
  const elRe = /<(\w+)([^>]*)>([^<]*)<\/\1>/g;
  let match;
  while ((match = elRe.exec(slideHtml)) !== null) {
    const tag = match[1];
    const attrs = match[2];
    const inner = match[3];
    const clsMatch = attrs.match(/class="([^"]*)"/);
    const classes = clsMatch ? clsMatch[1].split(/\s+/).filter(Boolean) : [];
    const styleMatch = attrs.match(/style="([^"]*)"/);
    const inlineStyle = styleMatch ? styleMatch[1] : '';
    const directText = inner.replace(/<[^>]+>/g, '').trim();
    elements.push({ tag, classes, inlineStyle, text: directText, html: match[0] });
  }
  return elements;
}

// ═══════════════════════════════════════════════════════════════
// STYLE RESOLUTION
// ═══════════════════════════════════════════════════════════════

function resolveProperty(el, prop, cssRules, rootVars) {
  if (el.inlineStyle) {
    const inline = parseInlineStyle(el.inlineStyle);
    if (inline[prop]) return resolveVar(inline[prop], rootVars);
  }
  const allClasses = [...el.classes, '__tag__' + el.tag];
  const matches = findMatchingRules(allClasses, cssRules);
  for (const rule of matches) {
    if (rule.props[prop]) return resolveVar(rule.props[prop], rootVars);
  }
  return null;
}

function parseInlineStyle(style) {
  const props = {};
  if (!style) return props;
  for (const m of style.matchAll(/([\w-]+)\s*:\s*([^;]+);?/g)) {
    props[m[1].trim()] = m[2].trim();
  }
  return props;
}

function resolveBackground(el, slide, cssRules, rootVars) {
  const ownBg = resolveProperty(el, 'background', cssRules, rootVars, null)
    || resolveProperty(el, 'background-color', cssRules, rootVars, null);
  if (ownBg) return ownBg;

  for (const cls of slide.classes) {
    for (const rule of cssRules) {
      const parts = rule.selector.split(/\s+/);
      if (parts.length === 1 && parts[0] === '.' + cls) {
        const bg = rule.props['background'] || rule.props['background-color'];
        if (bg) return resolveVar(bg, rootVars);
      }
    }
  }

  if (slide.classes.includes('photo-hero') || slide.classes.includes('cta')) return '#000000';
  if (slide.classes.includes('photo-top')) return '#000000';
  return null;
}

function resolveFontSize(el, cssRules, rootVars) {
  return resolveProperty(el, 'font-size', cssRules, rootVars, null);
}

function resolveFontFamily(el, cssRules, rootVars) {
  const raw = resolveProperty(el, 'font-family', cssRules, rootVars, null);
  if (!raw) return null;
  return raw.split(',')[0].trim().replace(/['"]/g, '');
}

function resolveColor(el, cssRules, rootVars) {
  return resolveProperty(el, 'color', cssRules, rootVars, null);
}

function resolvePosition(el, cssRules, rootVars) {
  const pos = resolveProperty(el, 'position', cssRules, rootVars, null);
  if (pos !== 'absolute') return null;
  return {
    top: resolveProperty(el, 'top', cssRules, rootVars, null),
    bottom: resolveProperty(el, 'bottom', cssRules, rootVars, null),
    left: resolveProperty(el, 'left', cssRules, rootVars, null),
    right: resolveProperty(el, 'right', cssRules, rootVars, null),
  };
}

// ═══════════════════════════════════════════════════════════════
// ESCAPE HATCHES
// ═══════════════════════════════════════════════════════════════

function parseIgnores(cssText, html) {
  const ignored = new Set();
  const cssComments = [...cssText.matchAll(/\/\*\s*linter-ignore:\s*([\w-]+)\s*\*\//g)];
  for (const m of cssComments) {
    ignored.add(m[1].trim());
  }
  const htmlComments = [...(html || '').matchAll(/<!--\s*linter-ignore:\s*([\w-]+)\s*-->/g)];
  for (const m of htmlComments) {
    ignored.add(m[1].trim());
  }
  return ignored;
}

// ═══════════════════════════════════════════════════════════════
// P0 CHECKS
// ═══════════════════════════════════════════════════════════════

function checkContrast(slides, cssRules, rootVars) {
  const issues = [];
  for (const slide of slides) {
    const elems = extractTextElements(slide.html);
    for (const el of elems) {
      if (!el.text) continue;
      const color = resolveColor(el, cssRules, rootVars);
      if (!color) continue;
      const bg = resolveBackground(el, slide, cssRules, rootVars);
      if (!bg || bg.includes('gradient')) continue;

      const fgRgb = parseColor(color);
      const bgRgb = parseColor(bg);
      if (!fgRgb || !bgRgb) continue;

      const ratio = contrastRatio(fgRgb, bgRgb);
      if (ratio === null) continue;

      const fontSizeRaw = resolveFontSize(el, cssRules, rootVars);
      const fontSizePx = fontSizeRaw ? parseFloat(fontSizeRaw) : 0;
      const fontWeight = resolveProperty(el, 'font-weight', cssRules, rootVars, null);
      const isLarge = fontSizePx >= 18 || (fontSizePx >= 14 && fontWeight && +fontWeight >= 700);
      const threshold = isLarge ? WCAG_AA_LARGE : MIN_CONTRAST;

      if (ratio < threshold) {
        issues.push({
          slide: slide.index,
          element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
          text: el.text.slice(0, 40),
          ratio: ratio.toFixed(1),
          required: threshold,
          fg: color,
          bg,
        });
      }
    }
  }
  return issues;
}

function checkFontSizes(slides, cssRules, rootVars) {
  const issues = [];
  const systemClasses = new Set(['byline', 'logo', 'dot', 'who', 'swipe', 'eyebrow', 'pilar-name', 'callout-label', 'nicho']);

  for (const slide of slides) {
    const elems = extractTextElements(slide.html);
    for (const el of elems) {
      if (!el.text) continue;
      if (el.classes.some(c => systemClasses.has(c))) continue;

      const fontSizeRaw = resolveFontSize(el, cssRules, rootVars);
      if (!fontSizeRaw) continue;
      const px = parseFloat(fontSizeRaw);
      if (isNaN(px) || px >= MIN_BODY_PX) continue;

      issues.push({
        slide: slide.index,
        element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
        text: el.text.slice(0, 40),
        fontSize: px,
        minimum: MIN_BODY_PX,
      });
    }
  }
  return issues;
}

function checkTypographyCount(slides, cssRules, rootVars) {
  const issues = [];
  const systemClasses = new Set(['byline', 'logo', 'dot', 'who', 'swipe', 'eyebrow', 'hairline']);

  for (const slide of slides) {
    const families = new Set();
    const sizes = new Set();
    const elems = extractTextElements(slide.html);
    for (const el of elems) {
      if (el.classes.some(c => systemClasses.has(c))) continue;
      if (!el.text) continue;

      const family = resolveFontFamily(el, cssRules, rootVars);
      if (family) families.add(family);

      const size = resolveFontSize(el, cssRules, rootVars);
      if (size) sizes.add(size);
    }

    if (families.size > MAX_FONT_FAMILIES) {
      issues.push({
        slide: slide.index,
        count: families.size,
        max: MAX_FONT_FAMILIES,
        found: [...families],
      });
    }
    if (sizes.size > MAX_FONT_SIZES) {
      issues.push({
        slide: slide.index,
        count: sizes.size,
        max: MAX_FONT_SIZES,
        found: [...sizes],
      });
    }
  }
  return issues;
}

// ═══════════════════════════════════════════════════════════════
// P1 CHECKS
// ═══════════════════════════════════════════════════════════════

function checkSafeZones(slides, cssRules, rootVars) {
  const issues = [];

  for (const slide of slides) {
    const elems = extractTextElements(slide.html);
    for (const el of elems) {
      if (!el.text) continue;
      const pos = resolvePosition(el, cssRules, rootVars);
      if (!pos) {
        // ponytail: flow text horizontal safe zone check — elements without position:absolute
        // compute X from left, margin-left, padding-left; default to 0
        const flowLeft = parseFloat(resolveProperty(el, 'left', cssRules, rootVars, null)
          || resolveProperty(el, 'margin-left', cssRules, rootVars, null)
          || resolveProperty(el, 'padding-left', cssRules, rootVars, null)
          || '0');
        if (flowLeft < SAFE_ZONE.xMin) {
          issues.push({
            slide: slide.index,
            element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
            text: el.text.slice(0, 40),
            zone: 'left-crop',
            x: flowLeft,
            detail: `X=${flowLeft} < safe ${SAFE_ZONE.xMin} (flow text cropped in 3:4 grid)`,
          });
        }
        continue;
      }

      const px = (v) => v ? parseFloat(v) : null;
      const top = px(pos.top);
      const bottom = px(pos.bottom);
      const left = px(pos.left);
      const right = px(pos.right);

      if (bottom !== null && bottom < UI_OVERLAY_BOTTOM) {
        const yPos = CANVAS.h - bottom;
        if (yPos > CANVAS.h - UI_OVERLAY_BOTTOM) {
          issues.push({
            slide: slide.index,
            element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
            text: el.text.slice(0, 40),
            zone: 'bottom-overlay',
            y: yPos,
            detail: `Y=${yPos} within bottom ${UI_OVERLAY_BOTTOM}px overlay`,
          });
        }
      }

      // ponytail: byline and swipe are decorative, intentionally placed
    const safeZoneSystemClasses = new Set(['byline', 'logo', 'who', 'dot', 'swipe']);
    const isSystem = el.classes.some(c => safeZoneSystemClasses.has(c));
    if (top !== null && top < UI_OVERLAY_TOP && !isSystem) {
        issues.push({
          slide: slide.index,
          element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
          text: el.text.slice(0, 40),
          zone: 'top-overlay',
          y: top,
          detail: `Y=${top} within top ${UI_OVERLAY_TOP}px overlay`,
        });
      }

      if (left !== null && left < SAFE_ZONE.xMin) {
        issues.push({
          slide: slide.index,
          element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
          text: el.text.slice(0, 40),
          zone: 'left-crop',
          x: left,
          detail: `X=${left} < safe ${SAFE_ZONE.xMin} (cropped in 3:4 grid)`,
        });
      }
      if (right !== null && right < (CANVAS.w - SAFE_ZONE.xMax)) {
        const xPos = CANVAS.w - right;
        if (xPos > SAFE_ZONE.xMax) {
          issues.push({
            slide: slide.index,
            element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
            text: el.text.slice(0, 40),
            zone: 'right-crop',
            x: xPos,
            detail: `X=${xPos} > safe ${SAFE_ZONE.xMax} (cropped in 3:4 grid)`,
          });
        }
      }
    }
  }
  return issues;
}

function checkSpacing(slides, cssRules, rootVars) {
  const issues = [];
  // Group paddings by slide type AND CSS selector (ponytail: only compare same selector)
  const byKey = {};

  for (const slide of slides) {
    const slideType = slide.classes.filter(c => !['slide','bg-purple','bg-deep'].includes(c)).sort().join('+');
    // Collect padding from rules that target slide-level classes
    for (const cls of slide.classes) {
      for (const rule of cssRules) {
        // Only match rules where the selector IS exactly the class (slide-level, not descendants)
        if (rule.selector === '.' + cls) {
          const pad = rule.props['padding'];
          if (pad) {
            const key = slideType + '::' + rule.selector;
            if (!byKey[key]) byKey[key] = [];
            byKey[key].push({ slide: slide.index, selector: rule.selector, padding: resolveVar(pad, rootVars) });
          }
        }
      }
    }
  }

  for (const [, group] of Object.entries(byKey)) {
    if (group.length < 2) continue;
    const first = group[0].padding;
    for (let i = 1; i < group.length; i++) {
      if (group[i].padding !== first) {
        issues.push({
          slide: group[i].slide,
          element: `${group[i].selector}`,
          padding: group[i].padding,
          expected: first,
          baseline: group[0].slide,
        });
      }
    }
  }
  return issues;
}

// ═══════════════════════════════════════════════════════════════
// P2 CHECKS
// ═══════════════════════════════════════════════════════════════

function checkEmphasisArea(slides, cssRules, rootVars) {
  const issues = [];
  const yellowHex = resolveVar('var(--yellow)', rootVars) || '#F2C94C';

  for (const slide of slides) {
    let totalTextElems = 0;
    let yellowElems = 0;
    const elems = extractTextElements(slide.html);

    const emphasisSystemClasses = new Set(['eyebrow', 'byline', 'logo', 'who', 'swipe', 'pilar-num', 'pilar-name', 'callout-label', 'callout-num', 'obl', 'punch']);
    for (const el of elems) {
      if (!el.text) continue;
      if (el.classes.some(c => emphasisSystemClasses.has(c))) continue;
      totalTextElems++;

      const color = resolveColor(el, cssRules, rootVars);
      if (color) {
        const resolved = resolveVar(color, rootVars);
        if (resolved.toLowerCase() === yellowHex.toLowerCase()) {
          yellowElems++;
          continue;
        }
      }

      if (el.inlineStyle && el.inlineStyle.toLowerCase().includes(yellowHex.toLowerCase())) {
        yellowElems++;
      }
    }

    if (totalTextElems > 0) {
      const pct = Math.round((yellowElems / totalTextElems) * 100);
      if (pct > MAX_YELLOW_PCT) {
        issues.push({
          slide: slide.index,
          yellowCount: yellowElems,
          totalCount: totalTextElems,
          percent: pct,
          max: MAX_YELLOW_PCT,
        });
      }
    }
  }
  return issues;
}

function checkRawHex(cssText, html, rootVars) {
  const issues = [];
  const tokenHexes = new Set([...TOKEN_HEXES].map(h => h.toLowerCase()));
  for (const val of Object.values(rootVars)) {
    if (val.startsWith('#')) tokenHexes.add(val.toLowerCase());
  }

  const cssBody = stripComments(cssText)
    .replace(/:root\s*\{[^}]*\}/g, '');

  // ponytail: skip hexes inside gradient functions — gradient stops are decorative
  function isInGradient(val, hexMatch) {
    const beforeHex = val.slice(0, hexMatch.index);
    // Check if the hex is inside a gradient function
    const openParens = (beforeHex.match(/\(/g) || []).length;
    const closeParens = (beforeHex.match(/\)/g) || []).length;
    return beforeHex.includes('gradient') && openParens > closeParens;
  }
  const hexRe = /:\s*([^;]*#[0-9a-fA-F]{3,8}[^;]*);/g;
  let match;
  const seen = new Set(); // ponytail: deduplicate by hex value
  while ((match = hexRe.exec(cssBody)) !== null) {
    const val = match[1];
    const hexMatches = [...val.matchAll(/#[0-9a-fA-F]{3,8}/g)];
    for (const hm of hexMatches) {
      const hex = hm[0].toLowerCase();
      if (tokenHexes.has(hex) || SAFE_RAW_HEXES.has(hex) || seen.has(hex)) continue;
      const before = val.slice(0, hm.index).trim();
      if (before.endsWith('rgba(') || before.endsWith('rgb(')) continue;
      if (isInGradient(val, hm)) continue;
      seen.add(hex);
      issues.push({
        hex,
        context: val.slice(Math.max(0, hm.index - 20), hm.index + hm[0].length + 20).trim(),
        suggestion: `Use a design token var(--*) instead of raw ${hex}`,
      });
    }
  }
  return issues;
}

// ═══════════════════════════════════════════════════════════════
// P2 CHECKS (continued)

// ponytail: replaces silent gradient/null/unparseable-background skips in checkContrast
// with per-slide deduplicated P2 advisories. Dedup prevents advisory flood on multi-element slides.
function checkUnresolvableBackgrounds(slides, cssRules, rootVars) {
  const issues = [];
  for (const slide of slides) {
    const elems = extractTextElements(slide.html);
    const foundTypes = new Set();
    for (const el of elems) {
      if (!el.text) continue;
      const bg = resolveBackground(el, slide, cssRules, rootVars);
      let reason = null;
      let ratioEstimate = null;
      if (!bg) {
        reason = 'cannot determine background color';
      } else if (bg.includes('gradient')) {
        // ponytail: sample gradient stops and compute worst-case contrast
        const stops = [...bg.matchAll(/rgba?\([^)]+\)|#[0-9a-fA-F]{3,8}/g)];
        if (stops.length > 0) {
          const textColor = resolveColor(el, cssRules, rootVars) || '#FFFFFF';
          const textRgb = parseColor(textColor);
          let minRatio = Infinity;
          for (const stop of stops) {
            const stopRgb = parseColor(stop[0]);
            if (stopRgb && textRgb) {
              const ratio = contrastRatio(textRgb, stopRgb);
              if (ratio !== null && ratio < minRatio) minRatio = ratio;
            }
          }
          if (minRatio !== Infinity) {
            ratioEstimate = minRatio.toFixed(1);
            reason = null; // we have a real estimate, don't use generic reason
          }
        }
        if (!ratioEstimate) {
          reason = 'gradient background';
        }
      } else {
        const bgRgb = parseColor(bg);
        if (!bgRgb) {
          reason = 'cannot parse background color value';
        }
      }
      if (ratioEstimate !== null) {
        const threshold = ratioEstimate >= MIN_CONTRAST ? 'passes' : 'below';
        const key = `gradient-estimate-${ratioEstimate}`;
        if (!foundTypes.has(key)) {
          foundTypes.add(key);
          issues.push({
            slide: slide.index,
            element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
            text: el.text.slice(0, 40),
            ratio: ratioEstimate,
            required: MIN_CONTRAST,
            detail: `Gradient background — worst-case contrast ≈ ${ratioEstimate}:1 (${threshold} ${MIN_CONTRAST}:1). Verify manually.`,
          });
        }
      } else if (reason && !foundTypes.has(reason)) {
        foundTypes.add(reason);
        issues.push({
          slide: slide.index,
          element: el.tag + (el.classes.length ? '.' + el.classes.join('.') : ''),
          text: el.text.slice(0, 40),
          reason,
          detail: `${reason} — cannot automatically verify text contrast. Verify manually.`,
        });
      }
    }
  }
  return issues;
}

// ═══════════════════════════════════════════════════════════════
// P0 CHECK: BYLINE PRESENCE
// ═══════════════════════════════════════════════════════════════

function checkBylinePresence(slides) {
  const issues = [];
  for (const slide of slides) {
    // Only check slides with data-image-template="founder-portrait"
    const hasFounderTemplate = slide.html.includes('data-image-template="founder-portrait"');
    if (!hasFounderTemplate) continue;

    // Check for .byline .who element (founder name)
    const hasBylineWho = /<[^>]+class="[^"]*\bwho\b[^"]*"[^>]*>/i.test(slide.html);
    if (!hasBylineWho) {
      issues.push({
        slide: slide.index,
        element: '.byline .who',
        text: 'founder byline',
        detail: 'Founder-portrait slide missing .byline .who element — brand violation.',
      });
    }
  }
  return issues;
}

// ═══════════════════════════════════════════════════════════════
// P2 CHECK: TYPOGRAPHIC RATIO
// ═══════════════════════════════════════════════════════════════

function checkTypographicRatio(slides, cssRules, rootVars) {
  const issues = [];
  const headingToBodyRatio = _tok?.typography?.headingToBodyRatio ?? 2.5;
  const systemClasses = new Set(['byline', 'logo', 'swipe', 'eyebrow', 'dot', 'who', 'pilar-name', 'pilar-num', 'callout-label', 'callout-num', 'nicho', 'hairline']);

  for (const slide of slides) {
    // Only check text-style slides (not photo slides)
    if (!slide.classes.some(c => ['text-slide', 'pilar', 'bento', 'comparison', 'stat', 'glass', 'cheatsheet', 'tutorial', 'quote'].includes(c))) continue;

    const elems = extractTextElements(slide.html);
    const fontSizes = [];
    for (const el of elems) {
      if (!el.text) continue;
      if (el.classes.some(c => systemClasses.has(c))) continue;
      const sizeRaw = resolveFontSize(el, cssRules, rootVars);
      if (!sizeRaw) continue;
      const px = parseFloat(sizeRaw);
      if (isNaN(px) || px <= 0) continue;
      fontSizes.push(px);
    }

    // Need at least 2 non-system font sizes to compute ratio
    if (fontSizes.length < 2) continue;

    fontSizes.sort((a, b) => b - a); // descending
    const largest = fontSizes[0];
    const secondLargest = fontSizes[1];
    const ratio = largest / secondLargest;

    if (ratio < headingToBodyRatio) {
      issues.push({
        slide: slide.index,
        ratio: ratio.toFixed(1),
        required: headingToBodyRatio,
        largest: largest + 'px',
        secondLargest: secondLargest + 'px',
        detail: `Heading-to-body ratio ${ratio.toFixed(1)}:1 < ${headingToBodyRatio}:1 (${largest}px / ${secondLargest}px). Add font size hierarchy.`,
      });
    }
  }
  return issues;
}

// ═══════════════════════════════════════════════════════════════
// REPORTER
// ═══════════════════════════════════════════════════════════════

function formatIssue(priority, check, issue) {
  const prefix = priority === 'P0' ? '  ✗' : priority === 'P1' ? '  ⚠' : '  ℹ';
  const loc = issue.slide ? `slide ${issue.slide}` : 'global';
  const el = issue.element ? ` (${issue.element})` : '';
  const text = issue.text ? ` "${issue.text}"` : '';

  switch (check) {
    case 'contrast-ratio':
      return `${prefix} ${loc}${el}${text} — contrast ${issue.ratio}:1 < ${issue.required}:1 (${issue.fg} on ${issue.bg})`;
    case 'font-size-min':
      return `${prefix} ${loc}${el}${text} — font-size ${issue.fontSize}px < ${issue.minimum}px minimum`;
    case 'typography-count':
      return `${prefix} ${loc} — ${issue.count} font sizes (max ${issue.max}): ${(issue.found||[]).join(', ')}`;
    case 'safe-zones':
      return `${prefix} ${loc}${el}${text} — ${issue.detail}`;
    case 'spacing-consistency':
      return `${prefix} ${loc}${el} — padding ${issue.padding} != baseline ${issue.expected} (slide ${issue.baseline})`;
    case 'emphasis-area':
      return `${prefix} ${loc} — ${issue.percent}% yellow elements (${issue.yellowCount}/${issue.totalCount}), max ${issue.max}%`;
    case 'raw-hex':
      return `${prefix} global — raw hex ${issue.hex} (${issue.suggestion})`;
    case 'gradient-contrast':
      return `${prefix} ${loc}${el} — ${issue.detail}`;
    case 'byline-presence':
      return `${prefix} ${loc} — ${issue.detail}`;
    case 'typographic-ratio':
      return `${prefix} ${loc} — ${issue.detail}`;
    default:
      return `${prefix} ${loc} — ${JSON.stringify(issue)}`;
  }
}

function report(results, jsonMode) {
  const { p0, p1, p2, summary, ignored } = results;

  if (jsonMode) {
    console.log(JSON.stringify({ p0, p1, p2, summary, ignored: [...ignored] }, null, 2));
    return;
  }

  console.log('\n=== visual-hierarchy-linter v1.0.0 ===');
  console.log(`Input: ${summary.file} (${summary.slides} slides)`);

  console.log('\nP0 Checks (BLOCKING):');
  printCheckGroup('P0', ['contrast-ratio', 'font-size-min', 'typography-count', 'byline-presence'], p0, ignored);

  console.log('\nP1 Checks (WARNING):');
  printCheckGroup('P1', ['safe-zones', 'spacing-consistency'], p1, ignored);

  console.log('\nP2 Checks (ADVISORY):');
  printCheckGroup('P2', ['emphasis-area', 'raw-hex', 'gradient-contrast', 'typographic-ratio'], p2, ignored);

  const p0Blocking = p0.filter(i => !ignored.has(i._check)).length;
  const totalIssues = p0.length + p1.length + p2.length;
  const totalIgnored = ignored.size;
  console.log(`\n${totalIssues} issues found (${p0Blocking} P0, ${p1.length} P1, ${p2.length} P2)${totalIgnored ? ` + ${totalIgnored} ignored` : ''}`);
  if (totalIssues === 0 && totalIgnored === 0) console.log('✅ All checks passed.\n');
  else if (p0Blocking === 0) console.log('⚠ No blocking issues.\n');
  else console.log('❌ Blocking issues found.\n');
}

function printCheckGroup(priority, checkNames, issues, ignored) {
  for (const check of checkNames) {
    const found = issues.filter(i => i._check === check);
    if (found.length === 0) {
      console.log(`  ✓ ${check}: no issues`);
    } else if (ignored.has(check)) {
      console.log(`  - ${check}: IGNORED (linter-ignore)`);
    } else {
      for (const issue of found) {
        console.log(formatIssue(priority, check, issue));
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// MAIN LINT FUNCTION
// ═══════════════════════════════════════════════════════════════

function lint(html, filePath) {
  const styleMatch = html.match(/<style[^>]*>([\s\S]*?)<\/style>/);
  const cssText = styleMatch ? styleMatch[1] : '';
  const { rules: cssRules, rootVars } = parseCSS(cssText);

  const ignored = parseIgnores(cssText, html);
  const slides = parseSlides(html);

  const p0 = [], p1 = [], p2 = [];

  if (!ignored.has('contrast-ratio'))
    p0.push(...checkContrast(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'contrast-ratio' })));
  if (!ignored.has('font-size-min'))
    p0.push(...checkFontSizes(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'font-size-min' })));
  if (!ignored.has('typography-count'))
    p0.push(...checkTypographyCount(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'typography-count' })));
  if (!ignored.has('safe-zones'))
    p1.push(...checkSafeZones(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'safe-zones' })));
  if (!ignored.has('spacing-consistency'))
    p1.push(...checkSpacing(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'spacing-consistency' })));
  if (!ignored.has('emphasis-area'))
    p2.push(...checkEmphasisArea(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'emphasis-area' })));
  if (!ignored.has('raw-hex'))
    p2.push(...checkRawHex(cssText, html, rootVars).map(i => ({ ...i, _check: 'raw-hex' })));
  if (!ignored.has('gradient-contrast'))
    p2.push(...checkUnresolvableBackgrounds(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'gradient-contrast' })));
  if (!ignored.has('byline-presence'))
    p0.push(...checkBylinePresence(slides).map(i => ({ ...i, _check: 'byline-presence' })));
  if (!ignored.has('typographic-ratio'))
    p2.push(...checkTypographicRatio(slides, cssRules, rootVars).map(i => ({ ...i, _check: 'typographic-ratio' })));

  return { p0, p1, p2, summary: { file: filePath, slides: slides.length }, ignored };
}

// ═══════════════════════════════════════════════════════════════
// SELF-TEST: inline example HTML
// ═══════════════════════════════════════════════════════════════

const DEMO_HTML = `<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><style>
/* linter-ignore: emphasis-area */
:root {
  --purple: #5B3B8C;
  --purple-deep: #3F2766;
  --purple-d2: #34204F;
  --yellow: #F2C94C;
  --white: #FFFFFF;
  --cream: #EFE9DC;
  --muted: #C9BBE0;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #1a1a1a; }
.slide { width: 1080px; height: 1080px; position: relative; overflow: hidden; display: flex; flex-direction: column; }

.bg-purple { background: #5B3B8C; }
.text-slide { padding: 140px 120px 160px; justify-content: center; }
.text-slide .eyebrow { font-family: 'InterV'; font-weight: 700; font-size: 36px; color: #F2C94C; }
.text-slide .setup { font-family: 'InterV'; font-weight: 400; font-size: 48px; line-height: 1.35; color: #FFFFFF; }
.text-slide .punch { font-family: 'Outfit'; font-weight: 700; font-size: 96px; color: #F2C94C; }

.text-slide .low-contrast { font-size: 24px; color: #C9BBE0; background: #FFFFFF; }
.text-slide .too-small { font-size: 18px; color: #FFFFFF; }

.text-slide .s1 { font-size: 32px; color: #FFFFFF; }
.text-slide .s2 { font-size: 36px; color: #FFFFFF; }
.text-slide .s3 { font-size: 40px; color: #FFFFFF; }
.text-slide .s4 { font-size: 44px; color: #F2C94C; }

.photo-hero { background: #000; }
.photo-hero .swipe { position: absolute; right: 80px; bottom: 70px; font-size: 40px; color: #F2C94C; }

.raw-hex-demo { color: #BADBAD; background: #FACADE; }
</style></head><body>

<div class="slide text-slide bg-purple">
  <div class="eyebrow">PASS SLIDE</div>
  <div class="setup">This text has good contrast: white on purple.</div>
  <div class="punch">GOOD</div>
</div>

<div class="slide text-slide bg-purple">
  <div class="eyebrow">FAIL SLIDE</div>
  <div class="low-contrast">Cream on purple fails WCAG AA 4.5:1.</div>
  <div class="too-small">This text is only 18px, below 20px minimum.</div>
</div>

<div class="slide text-slide bg-purple">
  <span class="s1">Size 32px</span>
  <span class="s2">Size 36px</span>
  <span class="s3">Size 40px</span>
  <span class="s4">Size 44px</span>
</div>

<div class="slide photo-hero">
  <div class="swipe">Desliza →</div>
</div>

<div class="slide text-slide bg-purple">
  <div class="setup">Slide 5 has a raw hex in CSS (check global result).</div>
</div>

<div class="slide text-slide bg-purple">
  <div class="setup">Consistent spacing with slide 1.</div>
</div>


<div class="slide text-slide bg-purple">
  <!-- linter demo: gradient background — should produce P2 advisory -->
  <div class="gradient-bg-demo" style="background: linear-gradient(0deg, #5B3B8C, #3F2766); font-size: 24px; color: #FFFFFF;">Text on gradient — contrast not verified automatically.</div>
</div>



<div class="slide photo-hero" data-image-template="founder-portrait">
  <!-- linter demo: founder-portrait slide WITHOUT .byline .who — should trigger byline-presence P0 -->
  <div class="topscrim"></div>
  <div class="content"><h1>Founder slide — no byline</h1></div>
</div>

<div class="slide text-slide bg-purple">
  <!-- linter demo: two font sizes at 32px and 28px — ratio 1.14:1 < 2.5:1 -->
  <div class="setup" style="font-size: 32px; color: #FFFFFF;">Heading text 32px</div>
  <div class="setup" style="font-size: 28px; color: #FFFFFF;">Body text 28px</div>
</div>

</body></html>`;


function demo() {
  console.log('=== DEMO: linting inline example HTML ===\n');
  console.log('This example includes:');
  console.log('  Slide 1: All checks PASS');
  console.log('  Slide 2: Contrast FAIL (muted on white) + Font-size FAIL (18px)');
  console.log('  Slide 3: Typography count FAIL (4 font sizes)');
  console.log('  Slide 4: Safe zone FAIL (bottom overlay)');
  console.log('  Slide 5: Raw hex FAIL (#BADBAD, #FACADE in CSS)');
  console.log('  Slide 6: Consistent spacing');
  console.log('  Slide 7: Gradient with contrast estimate (enhanced)');
  console.log('  Slide 8: Founder-portrait without byline (byline-presence P0)');
  console.log('  Slide 9: Text slide with 32px/28px (typographic-ratio P2)');
  console.log('  emphasis-area: IGNORED via /* linter-ignore */');

  const results = lint(DEMO_HTML, '<demo>');
  report(results, false);
  return results;
}

// ═══════════════════════════════════════════════════════════════
// CLI
// ═══════════════════════════════════════════════════════════════

function main() {
  const args = process.argv.slice(2);

  if (args.includes('--demo')) {
    const results = demo();
    const p0Blocking = results.p0.filter(i => !results.ignored.has(i._check));
    process.exit(p0Blocking.length > 0 ? 1 : 0);
  }

  if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
    console.log('Usage: node linter.mjs <file.html> [--json] [--demo]');
    console.log('  <file.html>  HTML file to lint (output from build_carousel.cjs)');
    console.log('  --json       Output results as JSON');
    console.log('  --demo       Run self-test with inline example HTML');
    process.exit(0);
  }

  const filePath = args[0];
  if (!fs.existsSync(filePath)) {
    console.error(`File not found: ${filePath}`);
    process.exit(1);
  }

  const html = fs.readFileSync(filePath, 'utf8');
  const results = lint(html, filePath);
  report(results, args.includes('--json'));

  const p0Blocking = results.p0.filter(i => !results.ignored.has(i._check));
  process.exit(p0Blocking.length > 0 ? 1 : 0);
}

main();
