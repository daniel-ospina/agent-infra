#!/usr/bin/env node
/**
 * build_carousel.js — Node.js port of build_carousel.py
 * Generates a self-contained HTML file with all carousel slides,
 * embedding fonts as base64 and images as Cloudinary URLs.
 *
 * Usage: node build_carousel.js --script script.yaml --images selected-images.yaml --output carousel.html
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const tok = require('./tokens.json');

// ── TEMPLATE LOADING ─────────────────────────────────────────
// Load image templates from the images skill's templates directory.
// Templates define byline behavior, scrim intensity, and prompt shape.
// Path: relative to this script → ../../carousel-b2b-images/templates/
const templatesDir = path.join(__dirname, '..', '..', 'carousel-b2b-images', 'templates');
const templates = {};
try {
  const templateFiles = fs.readdirSync(templatesDir).filter(f => f.endsWith('.yaml'));
  for (const f of templateFiles) {
    const tpl = yaml.load(fs.readFileSync(path.join(templatesDir, f), 'utf8'));
    templates[tpl.name] = tpl;
  }
} catch (err) {
  console.warn('⚠️  Could not load image templates:', err.message);
  // Fall back to empty — byline defaults to true (show name)
}

/**
 * Resolve image_template from a slide, with needs_founder fallback for backward compat.
 * Returns the template name (string), or 'ambient-interior' as default.
 */
// NOTE: Keep in sync with images/SKILL.md §Step 0 — both map needs_founder → image_template.
// If the mapping changes, update both locations.
function resolveTemplateName(slide) {
  if (slide.image_template) {
    return slide.image_template;
  }
  if (slide.needs_founder !== undefined) {
    console.warn(`⚠️  Slide ${slide.number || '?'}: \`needs_founder\` is deprecated. Use \`image_template\` instead.`);
    return slide.needs_founder !== false ? 'founder-portrait' : 'ambient-interior';
  }
  return 'ambient-interior'; // default
}

/**
 * Get the byline boolean from the loaded template.
 * Falls back to true (show name) if template can't be loaded.
 */
function getTemplateByline(slide) {
  const name = resolveTemplateName(slide);
  const tpl = templates[name];
  return tpl ? tpl.byline !== false : true;
}

// ── SCRIM RESOLUTION ─────────────────────────────────────────
// ponytail: scrim map drives all gradient backgrounds from template YAML
const scrimCSS = {
  'max-purple': "linear-gradient(180deg, rgba(26,18,40,0) 0%, rgba(26,18,40,0) 20%, rgba(26,18,40,.55) 35%, rgba(26,18,40,.80) 48%, rgba(26,18,40,.97) 100%)",
  'extra-heavy-purple': "linear-gradient(180deg, rgba(26,18,40,0) 0%, rgba(26,18,40,0) 25%, rgba(26,18,40,.40) 38%, rgba(26,18,40,.70) 50%, rgba(26,18,40,.94) 100%)",
  'heavy-purple': "linear-gradient(180deg, rgba(52,32,79,0) 0%, rgba(52,32,79,0) 32%, rgba(52,32,79,.40) 40%, rgba(40,25,66,.72) 48%, rgba(26,18,40,.92) 55%, rgba(26,18,40,.96) 100%)",
  'medium-purple': "linear-gradient(180deg, rgba(26,16,40,0.20) 0%, rgba(26,16,40,0.50) 100%)",
  'light-purple': "linear-gradient(180deg, rgba(26,16,40,0.15) 0%, rgba(26,16,40,0.35) 100%)",
  'angled-light-purple': 'linear-gradient(105deg, rgba(52,32,79,0.88) 0%, rgba(40,25,66,0.82) 35%, rgba(26,18,40,0.25) 65%, rgba(26,18,40,0) 100%)',
  'none': "none"
};

function getScrimCSS(slide) {
  // Per-slide override takes priority over template scrim
  if (slide.scrim_override) {
    const css = scrimCSS[slide.scrim_override];
    if (!css) {
      const valid = Object.keys(scrimCSS).join(', ');
      console.warn('⚠️  Unknown scrim_override: ' + slide.scrim_override + ' on slide ' + (slide.number || '?') + '. Valid: ' + valid + '. Falling back to template scrim.');
    } else {
      return css;
    }
  }
  const name = resolveTemplateName(slide);
  const tpl = templates[name];
  if (!tpl || !tpl.scrim || !tpl.scrim.type) {
    return null; // fallback to CSS class default
  }
  const type = tpl.scrim.type;
  const css = scrimCSS[type];
  if (!css) {
    const valid = Object.keys(scrimCSS).join(', ');
    console.error('❌ Unknown scrim type: ' + type + '. Valid: ' + valid);
    process.exit(1);
  }
  return css;
}

// ── BRAND TOKENS ──────────────────────────────────────────────
const LOGO_SVG = `<svg viewBox="0 0 40 52" xmlns="http://www.w3.org/2000/svg"><path d="M20 0C9 0 0 9 0 20c0 14 20 32 20 32s20-18 20-32C40 9 31 0 20 0z" fill="#fff"/><path d="M22.5 9l-11 14h7l-2.5 11 11-14h-7z" fill="${tok.purple}"/></svg>`;

// ── FONT LOADING ──────────────────────────────────────────────
function loadFontBase64(fontPath) {
  return fs.readFileSync(fontPath).toString('base64');
}

function buildFontFace(fontsDir) {
  const outfit = loadFontBase64(path.join(fontsDir, 'outfit.ttf'));
  const inter = loadFontBase64(path.join(fontsDir, 'inter.ttf'));
  const interItalic = loadFontBase64(path.join(fontsDir, 'inter-italic.ttf'));
  
  return `
@font-face { font-family: 'Outfit'; src: url(data:font/ttf;base64,${outfit}) format('truetype'); font-weight: 700; font-style: normal; }
@font-face { font-family: 'InterV'; src: url(data:font/ttf;base64,${inter}) format('truetype'); font-weight: 400 600; font-style: normal; }
@font-face { font-family: 'InterV'; src: url(data:font/ttf;base64,${interItalic}) format('truetype'); font-weight: 400 600; font-style: italic; }
`;
}


// ── TOKEN HELPERS ─────────────────────────────────────────────
const rootBlock = `:root {
  --purple: ${tok.purple};
  --purple-deep: ${tok.purpleDeep};
  --purple-d2: ${tok.purpleD2};
  --yellow: ${tok.yellow};
  --white: ${tok.white};
  --cream: ${tok.cream};
  --muted: ${tok.muted};
}`;

const tokenize = (css) => css
  .replace(/#5B3B8C\\b/gi, 'var(--purple)')
  .replace(/#3F2766\\b/gi, 'var(--purple-deep)')
  .replace(/#34204F\\b/gi, 'var(--purple-d2)')
  .replace(/#F2C94C\\b/gi, 'var(--yellow)')
  .replace(/#FFFFFF\\b/gi, 'var(--white)')
  .replace(/#EFE9DC\\b/gi, 'var(--cream)')
  .replace(/#C9BBE0\\b/gi, 'var(--muted)')
  .replace(/#fff\\b/gi, 'var(--white);');

// ── CSS ───────────────────────────────────────────────────────
const CSS = (fontFace, canvas) => {
  const body = `
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #1a1a1a; display: flex; flex-direction: column; align-items: center; gap: 46px; padding: 46px 0; }
.lab { display: none; }  /* hide debug labels — not part of the design */
.slide { width: ${canvas.width}px; height: ${canvas.height}px; position: relative; overflow: hidden; display: flex; flex-direction: column; font-family: 'Outfit', sans-serif; }
.obl { display: inline-block; transform: skewX(-9deg); }

/* byline */
.byline { display: flex; align-items: center; gap: 14px; }

.byline svg { width: 28px; height: 36px; display: block; }
.byline .logo { font-family: 'Outfit'; font-weight: 700; font-size: 48px; color: #FFFFFF; letter-spacing: -.01em; text-shadow: 0 2px 12px rgba(0,0,0,0.6); }
.byline .dot { width: 10px; height: 10px; border-radius: 50%; background: #F2C94C; margin: 0 2px; }
.byline .who { font-family: 'InterV'; font-weight: 500; font-size: 36px; color: #C9BBE0; text-shadow: 0 2px 10px rgba(0,0,0,0.6); }
.eyebrow { font-family: 'InterV'; font-weight: 700; font-size: 36px; letter-spacing: .15em; text-transform: uppercase; color: #F2C94C; }

/* photo-hero (Type A — portada, cierre) */
.photo-hero { background: #000; }
.photo-hero .photo { position: absolute; inset: 0; background-size: cover; background-repeat: no-repeat; }
.photo-hero .topscrim { position: absolute; top: 0; left: 0; right: 0; height: 200px; z-index: 1; background: linear-gradient(180deg, rgba(26,16,40,.5), rgba(26,16,40,0)); }
.photo-hero .grad { position: absolute; inset: 0; background: linear-gradient(180deg, rgba(52,32,79,0) 0%, rgba(52,32,79,0) 32%, rgba(52,32,79,.40) 40%, rgba(40,25,66,.72) 48%, rgba(26,18,40,.92) 55%, rgba(26,18,40,.96) 100%); }
.photo-hero .byline { position: absolute; top: 70px; left: 80px; z-index: 3; }
.photo-hero .content { position: relative; z-index: 2; margin-top: auto; padding: 0 155px 120px; }
.photo-hero h1 { font-weight: 700; font-size: 108px; line-height: .95; color: #FFFFFF; letter-spacing: -.035em; margin-bottom: 28px; text-shadow: 0 4px 20px rgba(0,0,0,0.5); max-height: 3.2em; overflow: hidden; }
.photo-hero h1 .obl { color: #F2C94C; }
.photo-hero .sub { font-family: 'InterV'; font-weight: 500; font-size: 48px; line-height: 1.35; color: #EFE9DC; max-width: 820px; text-shadow: 0 2px 12px rgba(0,0,0,0.5); }
.photo-hero .swipe { position: absolute; right: 155px; bottom: 60px; z-index: 4; font-family: 'InterV'; font-weight: 600; font-size: 40px; color: #C9BBE0; opacity: 0.6; }

/* photo-top (Type A — historia) */
.photo-top { background: #000; position: relative; }
.photo-top .photo { position: absolute; inset: 0; background-size: cover; background-repeat: no-repeat; z-index: 0; }
.photo-top .photo .tint { position: absolute; inset: 0; background: #5B3B8C; opacity: .06; mix-blend-mode: color; }
.photo-top .photo .fade { position: absolute; inset: 0; background: linear-gradient(180deg, rgba(52,32,79,.10) 24%, rgba(52,32,79,.72) 54%, rgba(40,25,66,.99) 100%); }
.photo-top .topscrim { position: absolute; top: 0; left: 0; right: 0; height: 200px; z-index: 1; background: linear-gradient(180deg, rgba(26,16,40,.5), rgba(26,16,40,0)); }
.photo-top .body { position: relative; z-index: 2; margin-top: auto; padding: 0 155px 120px; display: flex; flex-direction: column; gap: 28px; }
.photo-top .lead { font-weight: 600; font-size: 60px; line-height: 1.08; color: #FFFFFF; letter-spacing: -.025em; text-shadow: 0 2px 18px rgba(26,16,40,.4); }
.photo-top .lead .obl { color: #F2C94C; }
.photo-top .small { font-family: 'InterV'; font-weight: 400; font-size: 40px; color: #fff; line-height: 1.34; text-shadow: 0 2px 14px rgba(26,16,40,.45); }
.photo-top .small em { font-style: italic; color: #F2C94C; font-weight: 500; }
.photo-top .small b { color: #fff; font-weight: 600; font-style: normal; }
.photo-top .eyebrow { position: relative; z-index: 2; font-family: 'InterV'; font-weight: 700; font-size: 36px; letter-spacing: .15em; text-transform: uppercase; color: #F2C94C; margin-bottom: 28px; }

/* text-slide (Type B) */
/* ── TEXT SLIDES (Type B) ── */
.text-slide { padding: 120px 155px 140px; justify-content: center; display: flex; flex-direction: column; }
.bg-purple { background: #5B3B8C; }
.bg-deep { background: #34204F; }

/* Eyebrow — small label at top */
.text-slide .eyebrow { font-family: 'InterV'; font-weight: 700; font-size: 52px; letter-spacing: .08em; text-transform: uppercase; color: #F2C94C; margin-bottom: 48px; position: relative; z-index: 2; }
.text-slide .title { font-family: 'Outfit'; font-weight: 700; font-size: 64px; line-height: 1.1; color: #FFFFFF; letter-spacing: -.02em; margin-bottom: 32px; position: relative; z-index: 2; }
.text-slide .title .obl { color: #F2C94C; }
.text-slide .photo { position: absolute; inset: 0; background-size: cover; background-repeat: no-repeat; z-index: 0; }
.text-slide .grad { position: absolute; inset: 0; z-index: 1; }

/* Hairline rule — architecture between label and body */
.text-slide .hairline { width: 280px; height: 1px; background: rgba(242,201,76,0.30); margin: 0 auto 48px; border: none; position: relative; z-index: 2; }

/* Setup lines — body copy, tight group (8px gap within group) */
.text-slide .setup { font-family: 'InterV'; font-weight: 400; font-size: 48px; line-height: 1.35; color: #FFFFFF; letter-spacing: -.01em; margin-bottom: 10px; position: relative; z-index: 2; }

/* Body emphasis — white at weight 600 for inline emphasis (NOT yellow — save yellow) */
.text-slide .setup .obl { color: #F2C94C; }
.text-slide .body-em .obl { color: #F2C94C; }
.text-slide .body-em { font-family: 'InterV'; font-weight: 600; font-size: 50px; line-height: 1.15; color: #FFFFFF; letter-spacing: -.01em; margin-bottom: 8px; }

/* Beat — intentional whitespace gap between thought groups (3-4× setup gap) */
.text-slide .beat { height: 0; margin-bottom: 56px; }

/* Big beat — larger gap before the hero punch line */
.text-slide .beat-lg { height: 0; margin-bottom: 80px; }

/* Hero punch — the ONE yellow element. Outfit 700, large. The stopper. */
.text-slide .punch { font-family: 'Outfit'; font-weight: 700; font-size: 96px; line-height: 1.1; color: #F2C94C; letter-spacing: -.035em; max-height: 2.2em; overflow: hidden; }

/* Number callout — giant number as graphic element */
.text-slide .callout-num { font-family: 'Outfit'; font-weight: 700; font-size: 140px; line-height: 1.0; color: #F2C94C; letter-spacing: -.04em; text-align: center; }
.text-slide .callout-label { font-family: 'InterV'; font-weight: 700; font-size: 34px; letter-spacing: .15em; text-transform: uppercase; color: #C9BBE0; text-align: center; margin-top: 8px; }

/* Money line — special big numbers */
.money { font-family: 'Outfit'; font-weight: 700; font-size: 76px; line-height: 1.15; color: #FFFFFF; letter-spacing: -.03em; margin-bottom: 28px; }

/* Simple insight — two-level: lead + big */
.simple-lead { font-family: 'InterV'; font-weight: 400; font-size: 40px; line-height: 1.4; color: #FFFFFF; margin-bottom: 24px; }
.simple-big { font-family: 'Outfit'; font-weight: 700; font-size: 58px; line-height: 1.2; color: #FFFFFF; letter-spacing: -.03em; margin-bottom: 40px; }
.simple-big .y { color: #F2C94C; }

/* pilar */
.pilar-tag { display: flex; align-items: center; gap: 22px; margin-bottom: 46px; }
.pilar-num { font-weight: 700; font-size: 46px; color: #5B3B8C; background: #F2C94C; width: 94px; height: 94px; border-radius: 24px; display: flex; align-items: center; justify-content: center; font-family: 'Outfit'; }
.pilar-name { font-family: 'InterV'; font-weight: 700; font-size: 34px; letter-spacing: .12em; text-transform: uppercase; color: #F2C94C; }
.pilar h2 { font-weight: 700; font-size: 86px; line-height: 1.1; color: #FFFFFF; letter-spacing: -.035em; margin: 0; font-family: 'Outfit'; }
.pilar .ptext { font-family: 'InterV'; font-weight: 400; font-size: 46px; line-height: 1.35; color: #FFFFFF; margin-bottom: 10px; }
.pilar .ptext b { color: #F2C94C; font-weight: 400; }
.pilar .ptext .y { color: #F2C94C; }
.pilar .ptext.emph { font-weight: 600; color: #F2C94C; }

/* verdict */
.verdict .top { font-weight: 700; font-size: 68px; line-height: 1.04; color: #FFFFFF; letter-spacing: -.03em; margin-bottom: 48px; font-family: 'Outfit'; }
.verdict .body { font-family: 'InterV'; font-weight: 400; font-size: 46px; line-height: 1.34; color: #FFFFFF; }
.verdict .body b { color: #FFFFFF; font-weight: 600; }
.verdict .body .y { color: #F2C94C; font-weight: 400; }

/* cta */
.cta { background: var(--purple); }
.cta .photo { position: absolute; inset: 0; background-size: cover; background-repeat: no-repeat; }
.cta .grad { position: absolute; inset: 0; background: linear-gradient(105deg, rgba(52,32,79,.55) 0%, rgba(52,32,79,.78) 42%, rgba(52,32,79,.96) 70%, #34204F 100%); }
.cta .topscrim { position: absolute; top: 0; left: 0; right: 0; height: 200px; z-index: 1; background: linear-gradient(180deg, rgba(26,16,40,.5), rgba(26,16,40,0)); }
.cta .byline { position: absolute; top: 70px; left: 80px; z-index: 3; }
.cta .content { position: relative; z-index: 2; margin-top: auto; padding: 0 155px 120px; max-width: 770px; }
.cta h1 { font-weight: 700; font-size: 78px; line-height: 1.02; color: #FFFFFF; letter-spacing: -.03em; margin-bottom: 30px; }
.cta h1 .obl { color: #F2C94C; }
.cta .sub { font-family: 'InterV'; font-weight: 400; font-size: 40px; line-height: 1.3; color: #EFE9DC; margin-bottom: 40px; }
.cta .nicho { font-family: 'InterV'; font-weight: 600; font-style: italic; font-size: 30px; color: #C9BBE0; margin-bottom: 36px; }
.cta .btn { display: inline-flex; align-items: center; gap: 14px; background: #F2C94C; color: #34204F; font-family: 'Outfit'; font-weight: 700; font-size: 38px; padding: 26px 44px; border-radius: 18px; letter-spacing: -.01em; }

/* ── BENTO GRID (P0 — +23% CTR, TurboSEO) ── */
.bento { background: var(--purple); padding: 100px 155px 120px; display: flex; flex-direction: column; gap: 64px; }
.bento .grid { display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 32px; flex: 1; }
.bento .card { background: var(--purple-d2); border-radius: 28px; padding: 48px; display: flex; flex-direction: column; justify-content: center; gap: 14px; }
.bento .card.highlight { background: var(--yellow); }
.bento .card.highlight .c-title { color: var(--purple-d2); }
.bento .card.highlight .c-text { color: var(--purple); }
.bento .c-title { font-family: 'Outfit'; font-weight: 700; font-size: 40px; color: var(--white); line-height: 1.15; }
.bento .c-text { font-family: 'InterV'; font-weight: 400; font-size: 30px; color: var(--cream); line-height: 1.35; }

/* ── COMPARISON (P0 — +31% feature page conversions) ── */
.comparison { background: var(--purple-d2); padding: 90px 155px 120px; display: flex; flex-direction: column; gap: 48px; }
.comparison h2 { font-family: 'Outfit'; font-weight: 700; font-size: 60px; color: var(--yellow); letter-spacing: -.03em; text-align: center; }
.comparison .cols { display: flex; gap: 24px; flex: 1; }
.comparison .col { flex: 1; background: var(--purple); border-radius: 28px; padding: 56px 48px; display: flex; flex-direction: column; gap: 24px; }
.comparison .col.before { opacity: 0.68; }
.comparison .col.after { border: 3px solid var(--yellow); opacity: 1; }
.comparison .col-label { font-family: 'InterV'; font-weight: 700; font-size: 28px; letter-spacing: .12em; text-transform: uppercase; }
.comparison .col.before .col-label { color: var(--muted); }
.comparison .col.after .col-label { color: var(--yellow); }
.comparison .col-title { font-family: 'Outfit'; font-weight: 700; font-size: 44px; color: var(--white); line-height: 1.12; }
.comparison .col-points { font-family: 'InterV'; font-weight: 400; font-size: 32px; color: var(--cream); line-height: 1.4; display: flex; flex-direction: column; gap: 10px; }

/* ── STAT CARD (P1 — micro-learning, 15-20 words) ── */
.stat { background: var(--purple-d2); display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 120px 100px; text-align: center; gap: 32px; }
.stat .number { font-family: 'Outfit'; font-weight: 700; font-size: 200px; color: var(--yellow); line-height: 1.0; letter-spacing: -.04em; }
.stat .label { font-family: 'InterV'; font-weight: 700; font-size: 46px; color: var(--white); line-height: 1.2; letter-spacing: -.01em; }
.stat .context { font-family: 'InterV'; font-weight: 400; font-size: 36px; color: var(--cream); line-height: 1.4; max-width: 700px; }

/* ── GLASS CARD (P1 — +15% time-on-page, Apple Liquid Glass) ── */
.glass { background: linear-gradient(135deg, var(--purple) 0%, var(--purple-d2) 100%); display: flex; align-items: center; justify-content: center; padding: 120px 80px; }
.glass .panel { background: rgba(255,255,255,0.07); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border: 1px solid rgba(255,255,255,0.10); border-radius: 36px; padding: 72px 64px; max-width: 860px; display: flex; flex-direction: column; gap: 32px; text-align: center; }
.glass .panel h2 { font-family: 'Outfit'; font-weight: 700; font-size: 68px; color: var(--white); letter-spacing: -.03em; line-height: 1.08; }
.glass .panel p { font-family: 'InterV'; font-weight: 400; font-size: 38px; color: var(--cream); line-height: 1.35; }

/* ── CHEAT SHEET (P1 — save-worthy = algorithm signal) ── */
.cheatsheet { background: var(--purple); padding: 90px 155px 120px; display: flex; flex-direction: column; gap: 44px; }
.cheatsheet h2 { font-family: 'Outfit'; font-weight: 700; font-size: 60px; color: var(--white); letter-spacing: -.03em; }
.cheatsheet .items { display: flex; flex-direction: column; gap: 26px; flex: 1; }
.cheatsheet .item { display: flex; gap: 22px; align-items: flex-start; }
.cheatsheet .item-num { font-family: 'Outfit'; font-weight: 700; font-size: 48px; color: var(--yellow); line-height: 1.0; min-width: 56px; }
.cheatsheet .item-text { font-family: 'InterV'; font-weight: 500; font-size: 36px; color: var(--white); line-height: 1.3; padding-top: 4px; }

/* ── TUTORIAL (P2 — one step per slide) ── */
.tutorial { background: var(--purple-d2); padding: 110px 155px 120px; display: flex; flex-direction: column; justify-content: center; gap: 32px; }
.tutorial .step-num { font-family: 'Outfit'; font-weight: 700; font-size: 110px; color: var(--yellow); line-height: 1.0; letter-spacing: -.04em; }
.tutorial h2 { font-family: 'Outfit'; font-weight: 700; font-size: 60px; color: var(--white); letter-spacing: -.03em; line-height: 1.1; }
.tutorial .inst { font-family: 'InterV'; font-weight: 400; font-size: 38px; color: var(--cream); line-height: 1.4; }

/* ── QUOTE (P2 — founder voice) ── */
.quote { background: var(--purple); display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 120px 110px; text-align: center; gap: 36px; }
.quote .mark { font-family: 'Outfit'; font-weight: 700; font-size: 150px; color: var(--yellow); line-height: 0.6; height: 50px; }
.quote .text { font-family: 'InterV'; font-weight: 500; font-style: italic; font-size: 50px; color: var(--white); line-height: 1.3; letter-spacing: -.01em; }
.quote .attr { font-family: 'InterV'; font-weight: 600; font-size: 34px; color: var(--muted); }


`;
  return fontFace + '\n' + rootBlock + '\n' + tokenize(body);
};
// ── SLIDE BUILDERS ────────────────────────────────────────────

// Conditional byline: show name only when founder is in the photo
function buildByline(showName = true) {
  if (showName) {
    return `<div class="byline">${LOGO_SVG}<span class="logo">eldato</span><span class="dot"></span><span class="who">Daniel Ospina · Fundador</span></div>`;
  }
  return `<div class="byline">${LOGO_SVG}<span class="logo">eldato</span></div>`;
}

function highlightEmphasis(text, emphasisWords = []) {
  let result = text;
  for (const word of emphasisWords) {
    // Use (?<![\w]) and (?![\w]) instead of \b — handles punctuation at word boundaries
    // \b fails when word ends with . , : ; ! ? because those are non-word chars
    result = result.replace(new RegExp(`(?<![\\w])(${escapeRegex(word)})(?![\\w])`, 'gi'), '<span class="obl">$1</span>');
  }
  return result;
}

function escapeRegex(str) { return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function buildPhotoHero(slide, images) {
  const img = images[slide.number];
  const imgStyle = img ? (() => {
    let url = img.cloudinary_url;
    // If it's a relative path (not http/https/data), resolve to absolute
    if (!url.startsWith('http') && !url.startsWith('data:')) {
      url = 'file://' + require('path').resolve(path.dirname(global.CLI_OPTS.output), url);
    }
    return `background-image:url(${url});background-position:${img.background_position || 'center 16%'};`;
  })() : '';
  const headline = highlightEmphasis(slide.copy.headline || '', slide.copy.emphasis || []);
  
  const scrim = getScrimCSS(slide);
  const templateName = resolveTemplateName(slide);
  return `<div class="slide photo-hero" data-image-template="${templateName}">
<div class="photo" style="${imgStyle}"></div>
<div class="grad"${scrim ? ` style="background:${scrim}"` : ''}></div>
${getTemplateByline(slide) ? '<div class="topscrim"></div>' : ''}
${buildByline(getTemplateByline(slide))}
<div class="content">
<h1>${headline}</h1>
${slide.copy.subtitle ? `<div class="sub">${slide.copy.subtitle.replace(/\n/g,'<br>')}</div>` : ''}
</div>
${slide.number === 1 ? '<div class="swipe">Desliza →</div>' : ''}
</div>`;
}

function buildPhotoTop(slide, images) {
  const img = images[slide.number];
  const imgStyle = img ? `background-image:url(${img.cloudinary_url});background-position:${img.background_position || 'center 28%'};` : '';
  const lead = highlightEmphasis(slide.copy.headline || '', slide.copy.emphasis || []);
  
  const scrim = getScrimCSS(slide);
  const templateName = resolveTemplateName(slide);
  return `<div class="slide photo-top" data-image-template="${templateName}">
<div class="photo" style="${imgStyle}"><div class="tint"></div><div class="fade"${scrim ? ` style="background:${scrim}"` : ''}></div></div>
${getTemplateByline(slide) ? '<div class="topscrim"></div>' : ''}
${buildByline(getTemplateByline(slide))}
<div class="body">
${slide.copy.eyebrow ? `<div class="eyebrow">${slide.copy.eyebrow}</div>` : ''}
<div class="lead">${lead}</div>
${slide.copy.subtitle ? `<div class="small">${slide.copy.subtitle.replace(/\n/g,'<br>')}</div>` : ''}
</div>
</div>`;
}

function buildTextSlide(slide, hasCssMap, imageMap) {
  const img = slide.needs_image ? (imageMap && imageMap[slide.number]) : null;
  const bgImageStyle = img ? (() => {
    let url = img.cloudinary_url;
    if (!url.startsWith('http') && !url.startsWith('data:')) {
      url = 'file://' + require('path').resolve(path.dirname(global.CLI_OPTS.output), url);
    }
    return `background-image:url(${url});background-position:${img.background_position || 'center center'};`;
  })() : '';
  const bgClass = slide.background === 'deep' ? 'bg-deep' : 'bg-purple';
  const eyebrow = slide.copy.eyebrow ? `<div class="eyebrow">${slide.copy.eyebrow}</div>` : '';
  const headline = slide.copy.headline ? `<div class="title">${highlightEmphasis(slide.copy.headline.replace(/\n/g,'<br>'), slide.copy.emphasis || [])}</div>` : '';
  const subtitle = slide.copy.subtitle ? `<div class="subtitle">${slide.copy.subtitle}</div>` : '';
  const hairline = (headline || subtitle) ? '<hr class="hairline">' : '';
  
  let bodyHtml = '';
  if (slide.copy.body) {
    // Split body into paragraphs
    // Split on explicit newlines first. If none, split on sentence boundaries (period+space+uppercase)
    let rawParagraphs;
    if (hasCssMap || global.CLI_OPTS?.passthrough) {
      // Passthrough mode: AI controls layout. Only split on double newlines.
      // Period-splitting is LEGACY (#4599) — it creates unwanted visual breaks.
      rawParagraphs = slide.copy.body.split(/\n{2,}/).filter(p => p.trim());
    } else {
      // Legacy mode: split on double newlines, then on sentence boundaries
      // Only used when no CSS map AND no --passthrough flag
      rawParagraphs = slide.copy.body.split(/\n{2,}/).filter(p => p.trim());
      if (rawParagraphs.length <= 1) {
        rawParagraphs = slide.copy.body.split(/(?<=\.)\s+(?=[A-ZÁÉÍÓÚÑ])/).filter(p => p.trim());
      }
    }
    const paragraphs = rawParagraphs;
    
    // Render all paragraphs as-is. No auto-formatting. No regrouping.
    // The copy skill owns punctuation — build script trusts what it receives.
    const allParagraphs = paragraphs.map(p => {
      const trimmed = p.trim();
      return `<div class="setup">${highlightEmphasis(trimmed.replace(/\n/g,'<br>'), slide.copy.emphasis || [])}</div>`;
    }).join('');
    
    // Optional punch line — ONLY when explicitly set via punch: field
    // emphasis words render inline as .obl (yellow body-size), never as .punch
    let punch = '';
    if (slide.copy.punch) {
      punch = `<div class="punch">${slide.copy.punch}</div>`;
    }
    
    bodyHtml = allParagraphs + (punch ? '<div class="beat"></div>' + punch : '');
  }
  
  const conceptBg = img ? `<div class="photo" style="${bgImageStyle}"></div><div class="grad" style="background:linear-gradient(180deg, rgba(26,18,40,0.35) 0%, rgba(26,18,40,0.65) 40%, rgba(26,18,40,0.88) 70%, rgba(26,18,40,0.97) 100%)"></div>` : '';
  return `<div class="slide text-slide ${bgClass}">
${conceptBg}
${eyebrow}
${headline}${subtitle}
${hairline}
${bodyHtml}
</div>`;
}

function buildPilarSlide(slide, pilarNum) {
  const pilarNames = {1: 'uno', 2: 'dos', 3: 'tres'};
  const body = slide.copy.body ? `<div class="setup">${highlightEmphasis(slide.copy.body, slide.copy.emphasis || [])}</div>` : '';
  // Punch — explicit punch: field takes priority; emphasis[0] fallback only if emphasis_style is not 'inline'
  let punch = '';
  if (slide.copy.punch) {
    punch = `<div class="punch">${slide.copy.punch}</div>`;
  } else if (slide.copy.emphasis_style !== 'inline' && slide.copy.emphasis && slide.copy.emphasis[0]) {
    punch = `<div class="punch">${slide.copy.emphasis[0]}</div>`;
  }
  
  return `<div class="slide text-slide bg-purple pilar">
<div class="pilar-tag"><span class="pilar-num">${pilarNum}</span><span class="pilar-name">Pilar ${pilarNames[pilarNum] || pilarNum}</span></div>
<div class="beat"></div>
<h2>${slide.copy.headline || ''}</h2>
<div class="beat"></div>
${body}
${punch ? '<div class="beat"></div>' + punch : ''}
</div>`;
}

function buildCTASlide(slide, images) {
  const img = images[slide.number];
  const imgStyle = img ? `background-image:url(${img.cloudinary_url});background-position:${img.background_position || 'center 12%'};` : '';
  const headline = highlightEmphasis(slide.copy.headline || '', slide.copy.emphasis || []);
  
  const scrim = getScrimCSS(slide);
  const templateName = resolveTemplateName(slide);
  return `<div class="slide cta" data-image-template="${templateName}">
<div class="photo" style="${imgStyle}"></div>
<div class="grad"${scrim ? ` style="background:${scrim}"` : ''}></div>
${getTemplateByline(slide) ? '<div class="topscrim"></div>' : ''}
${buildByline(getTemplateByline(slide))}
<div class="content">
<h1>${headline}</h1>
${slide.copy.subtitle ? `<div class="sub">${slide.copy.subtitle.replace(/\n/g,'<br>')}</div>` : ''}
<div class="btn">${slide.copy.cta || 'Link en la bio →'}</div>
</div>
</div>`;
}


// ── NEW TEMPLATES (layout-composer #4291) ─────────────────────

function buildBentoSlide(slide) {
  const headline = slide.copy.headline;
  const cards = slide.copy.cards || [];
  const gridHtml = cards.slice(0, 4).map(card => {
    const hl = card.highlight ? ' highlight' : '';
    return `<div class="card${hl}"><div class="c-title">${card.title || ''}</div>${card.text ? `<div class="c-text">${card.text}</div>` : ''}</div>`;
  }).join('');
  return `<div class="slide bento">
${headline ? `<h2>${headline}</h2>` : ''}
<div class="grid">${gridHtml}</div>
</div>`;
}

function buildComparisonSlide(slide) {
  const before = slide.copy.before || {};
  const after = slide.copy.after || {};
  const bp = (before.points || []).map(p => `<div>${p}</div>`).join('');
  const ap = (after.points || []).map(p => `<div>${p}</div>`).join('');
  return `<div class="slide comparison">
${slide.copy.headline ? `<h2>${slide.copy.headline}</h2>` : ''}
<div class="cols">
  <div class="col before">
    <div class="col-label">Antes</div>
    ${before.title ? `<div class="col-title">${before.title}</div>` : ''}
    ${bp ? `<div class="col-points">${bp}</div>` : ''}
  </div>
  <div class="col after">
    <div class="col-label">Después</div>
    ${after.title ? `<div class="col-title">${after.title}</div>` : ''}
    ${ap ? `<div class="col-points">${ap}</div>` : ''}
  </div>
</div>
</div>`;
}

function buildStatSlide(slide) {
  const stat = slide.copy.stat || slide.copy.headline || '';
  const label = slide.copy.label || slide.copy.subtitle || '';
  const context = slide.copy.body || '';
  return `<div class="slide stat">
<div class="number">${stat}</div>
${label ? `<div class="label">${label}</div>` : ''}
${context ? `<div class="context">${context}</div>` : ''}
</div>`;
}

function buildGlassSlide(slide) {
  const headline = slide.copy.headline || '';
  const body = slide.copy.body || '';
  return `<div class="slide glass">
<div class="panel">
  ${headline ? `<h2>${headline}</h2>` : ''}
  ${body ? `<p>${body}</p>` : ''}
  ${slide.copy.subtitle ? `<p>${slide.copy.subtitle.replace(/\n/g,'<br>')}</p>` : ''}
</div>
</div>`;
}

function buildCheatsheetSlide(slide) {
  const items = slide.copy.items || [];
  const itemsHtml = items.slice(0, 8).map((item, i) => {
    const text = typeof item === 'string' ? item : (item.text || '');
    return `<div class="item"><div class="item-num">${String(i + 1).padStart(2, '0')}</div><div class="item-text">${text}</div></div>`;
  }).join('');
  return `<div class="slide cheatsheet">
${slide.copy.headline ? `<h2>${slide.copy.headline}</h2>` : ''}
<div class="items">${itemsHtml}</div>
</div>`;
}

function buildTutorialSlide(slide) {
  const step = slide.copy.step || '';
  const headline = slide.copy.headline || '';
  const body = slide.copy.body || '';
  return `<div class="slide tutorial">
${step ? `<div class="step-num">${step}</div>` : ''}
${headline ? `<h2>${headline}</h2>` : ''}
${body ? `<div class="inst">${body}</div>` : ''}
</div>`;
}

function buildQuoteSlide(slide) {
  const text = slide.copy.body || slide.copy.headline || '';
  const attribution = slide.copy.attribution || slide.copy.subtitle || '';
  const role = slide.copy.role || '';
  return `<div class="slide quote">
<div class="mark">"</div>
<div class="text">${text}</div>
${attribution ? `<div class="attr">— ${attribution}${role ? `, ${role}` : ''}</div>` : ''}
</div>`;
}


// ── SAFE ZONE VALIDATION ─────────────────────────────────────
// ponytail: character-count heuristic; pixel measurement needs a real layout engine
function validateSafeZones(slides) {
  const sz = tok.safeZones;
  if (!sz) return;

  const canvasW = (tok.canvas && tok.canvas.width) || 1080;
  const maxHookChars = (canvasW / 27) | 0; // ~40 chars for 1080px, scales with canvas width
  const uiBottom = sz.uiOverlay?.bottom ?? 150;

  const issues = [];
  for (const [i, slide] of slides.entries()) {
    const num = i + 1;
    // Hook headline: flag if exceeding safe character budget
    if (slide.type === 'photo-hero' || slide.type === 'cta') {
      if (slide.copy.headline && slide.copy.headline.length > maxHookChars) {
        issues.push("slide " + num + ": headline " + slide.copy.headline.length + " chars (max ~" + maxHookChars + " for hook visibility in 1080px width)");
      }
    }
    // Swipe indicator: warn only if .swipe class exists in expected danger zone
    if (slide.type === 'photo-hero') {
      // ponytail: swipe at bottom:60px (Y≈1020) — well below content on 1:1 canvas
    }
  }
  if (issues.length) {
    console.warn('\u26a0\ufe0f  Safe zone warnings:');
    for (var j = 0; j < issues.length; j++) console.warn('  ' + issues[j]);
  }
}

// ── MAIN ──────────────────────────────────────────────────────

function buildCarousel(script, images, fontsDir, cssMap) {
  const fontFace = buildFontFace(fontsDir);
  const canvas = tok.canvas || { width: 1080, height: 1080 };
  
  // Validate script.yaml structure
  if (!script.slides || !Array.isArray(script.slides)) {
    console.error('❌ script.yaml: missing or invalid "slides" array');
    process.exit(1);
  }
  const validTypes = ['photo-hero', 'photo-top', 'text-slide', 'cta', 'pilar', 'bento', 'comparison', 'stat', 'glass', 'cheatsheet', 'tutorial', 'quote'];
  for (const [i, slide] of script.slides.entries()) {
    if (!slide.type) {
      console.error(`❌ Slide ${i+1}: missing "type" field`);
      process.exit(1);
    }
    if (!validTypes.includes(slide.type)) {
      console.error(`❌ Slide ${i+1}: unknown type "${slide.type}". Valid: ${validTypes.join(', ')}`);
      process.exit(1);
    }
    if (!slide.copy) {
      console.error(`❌ Slide ${i+1}: missing "copy" object`);
      process.exit(1);
    }
    if ((slide.type === 'photo-hero' || slide.type === 'photo-top' || slide.type === 'cta') && slide.needs_image && images && images.slides && !images.slides[i+1]) {
      console.warn(`⚠️  Slide ${i+1} (${slide.type}): needs_image=true but no image in selected-images.yaml`);
    }
  }

  const slides = script.slides;
  validateSafeZones(slides);
  // Only render used images (or images without status — backward compat). not_used images are excluded.
  const rawImageMap = (images && images.slides) ? images.slides : {};
  const imageMap = {};
  for (const [slideNum, img] of Object.entries(rawImageMap)) {
    if (img.status !== "not_used") {
      imageMap[slideNum] = img;
    }
  }
  
  let pilarCount = 0;
  const slideHtmls = slides.map((slide, i) => {
    let html;
    switch (slide.type) {
      case 'photo-hero':
        html = buildPhotoHero(slide, imageMap);
        break;
      case 'photo-top':
        html = buildPhotoTop(slide, imageMap);
        break;
      case 'text-slide':
        html = buildTextSlide(slide, !!cssMap, imageMap);
        break;
      case 'pilar':
        pilarCount++;
        html = buildPilarSlide(slide, pilarCount);
        break;
      case 'cta':
        html = buildCTASlide(slide, imageMap);
        break;
      case 'bento':
        html = buildBentoSlide(slide);
        break;
      case 'comparison':
        html = buildComparisonSlide(slide);
        break;
      case 'stat':
        html = buildStatSlide(slide);
        break;
      case 'glass':
        html = buildGlassSlide(slide);
        break;
      case 'cheatsheet':
        html = buildCheatsheetSlide(slide);
        break;
      case 'tutorial':
        html = buildTutorialSlide(slide);
        break;
      case 'quote':
        html = buildQuoteSlide(slide);
        break;
      default:
        html = buildTextSlide(slide, !!cssMap, imageMap);
    }
    // Inject data-slide attribute for scoped CSS selectors (#4581, #4599)
    // MUST use indexOf('>'), never regex — regex-based injection corrupted HTML
    const gt = html.indexOf('>');
    html = html.slice(0, gt) + ' data-slide="' + i + '"' + html.slice(gt);
    const perSlideStyle = (cssMap && cssMap[i]) ? `\n<style id="slide-${i}">${cssMap[i]}</style>` : '';
    return `<div class="lab">${String(i + 1).padStart(2, '0')}. ${slide.copy.headline || slide.copy.eyebrow || `Slide ${i + 1}`}</div>\n${html}${perSlideStyle}`;
  });
  
  const body = slideHtmls.join('\n');
  return `<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><style>${CSS(fontFace, canvas)}</style></head><body>${body}</body></html>`;
}

// ── CLI ───────────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--script' && args[i+1]) opts.script = args[++i];
    if (args[i] === '--images' && args[i+1]) opts.images = args[++i];
    if (args[i] === '--output' && args[i+1]) opts.output = args[++i];
    if (args[i] === '--fonts' && args[i+1]) opts.fonts = args[++i];
    if (args[i] === '--css-map' && args[i+1]) opts.cssMap = args[++i];
    if (args[i] === '--passthrough') opts.passthrough = true;
  }
  return opts;
}

function main() {
  global.CLI_OPTS = parseArgs();
  const opts = global.CLI_OPTS;
  if (!opts.script || !opts.output) {
    console.error('Usage: node build_carousel.js --script script.yaml --images selected-images.yaml --output carousel.html [--fonts ./fonts/] [--css-map map.json] [--passthrough]');
    process.exit(1);
  }
  
  const script = yaml.load(fs.readFileSync(opts.script, 'utf8'));
  const images = opts.images ? yaml.load(fs.readFileSync(opts.images, 'utf8')) : null;

  // ── Image Status Validation (#4574, #4599) ───────────────────
  // Validate image status and filter to only used images for rendering.
  // - discarded: hard error (failed quality checks or user-rejected)
  // - not_used: warning but kept in file (future reuse)
  // - used: rendered into slides
  // - no status: treated as used (backward compat)
  let notUsedWarnings = [];
  if (images && images.slides) {
    for (const [slideNum, img] of Object.entries(images.slides)) {
      if (img.status === 'discarded') {
        console.error(`❌ Slide ${slideNum}: image has status "discarded" — rejected by quality checks. Remove from selected-images.yaml first.`);
        process.exit(1);
      }
      if (img.status === 'not_used') {
        notUsedWarnings.push(slideNum);
      }
    }
    if (notUsedWarnings.length > 0) {
      console.warn(`⚠️  ${notUsedWarnings.length} image(s) marked "not_used" (slides: ${notUsedWarnings.join(',')}). These will not be rendered — kept for future reuse.`);
    }
  }

  const fontsDir = opts.fonts || path.join(__dirname, 'fonts');
  let cssMap = null;
  if (opts.cssMap) {
    try { cssMap = JSON.parse(fs.readFileSync(opts.cssMap, 'utf8')); }
    catch (e) { console.warn('⚠ Could not parse CSS map:', e.message); }
  }
  
  const html = buildCarousel(script, images, fontsDir, cssMap);
  fs.writeFileSync(opts.output, html);
  
  console.log(`✅ carousel.html written (${Math.round(html.length / 1024)} KB, ${script.slides.length} slides)`);
}

main();
