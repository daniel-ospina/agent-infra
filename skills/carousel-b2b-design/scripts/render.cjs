#!/usr/bin/env node
/**
 * render.js — Renders carousel slides to PNG via Playwright
 * Usage: node render.js --input carousel.html --output slides/
 */

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { scale: 1 };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--input' && args[i+1]) opts.input = args[++i];
    if (args[i] === '--output' && args[i+1]) opts.output = args[++i];
    if (args[i] === '--scale' && args[i+1]) opts.scale = parseFloat(args[++i]);
    if (args[i] === '--preview' && args[i+1]) opts.preview = args[++i];
  }
  return opts;
}

async function render(opts) {
  if (!opts.input || !opts.output) {
    console.error('Usage: node render.js --input carousel.html --output slides/ [--scale 1]');
    process.exit(1);
  }

  const htmlPath = path.resolve(opts.input);
  const outputDir = path.resolve(opts.output);
  
  if (!fs.existsSync(htmlPath)) {
    console.error(`❌ Input file not found: ${htmlPath}`);
    process.exit(1);
  }
  
  fs.mkdirSync(outputDir, { recursive: true });
  
  console.log(`🎨 Rendering carousel from ${htmlPath}`);
  
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1080, height: 1080 }, deviceScaleFactor: 1 });
  
  await page.goto(`file://${htmlPath}`, { waitUntil: 'networkidle' });
  
  // Get all slide elements
  const slides = await page.$$('.slide');
  console.log(`Found ${slides.length} slides`);
  
  const names = [];
  for (let i = 0; i < slides.length; i++) {
    const slideNum = String(i + 1).padStart(2, '0');
    
    // Get the label text for the filename
    const label = await page.$eval(`.lab:nth-of-type(${i + 1})`, el => el.textContent || '').catch(() => '');
    const nameSlug = label.replace(/^\d+\.\s*/, '').replace(/[^a-z0-9áéíóúñ_-]/gi, '_').toLowerCase().substring(0, 30) || `slide_${slideNum}`;
    const filename = `${slideNum}_${nameSlug}.png`;
    
    await slides[i].screenshot({
      path: path.join(outputDir, filename),
      type: 'png'
    });
    
    names.push(filename);
    console.log(`  ✅ ${filename}`);
  }
  
  // Write names.json for reference
  fs.writeFileSync(path.join(outputDir, 'names.json'), JSON.stringify(names, null, 2));
  
  await browser.close();
  console.log(`✅ Done — ${slides.length} slides rendered to ${outputDir}`);
  // Generate self-contained base64 preview if --preview flag is set
  if (opts.preview) {
    const previewPath = path.resolve(opts.preview);
    let previewHtml = '<!DOCTYPE html><html><head><meta charset="UTF-8"><style>body{background:#1a1a1a;display:flex;flex-direction:column;align-items:center;gap:40px;padding:40px;}.slide{width:540px;border-radius:12px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,.5);}.slide img{width:100%;display:block;}</style></head><body>';
    for (const name of names) {
      const pngPath = path.join(outputDir, name);
      if (fs.existsSync(pngPath)) {
        const b64 = fs.readFileSync(pngPath).toString('base64');
        previewHtml += `<div class="slide"><img src="data:image/png;base64,${b64}"></div>`;
      }
    }
    previewHtml += '</body></html>';
    fs.writeFileSync(previewPath, previewHtml);
    console.log(`  ✅ Preview: ${previewPath}`);
  }

}

render(parseArgs()).catch(err => {
  console.error('❌ Render failed:', err.message);
  process.exit(1);
});
