// Renders an SVG to a PNG of a given size with headless Chromium, on a transparent background.
// Used by make-appicon.sh. Needs Node.js and Playwright; nothing in the app or its build depends on it.
//
//   node scripts/icon/render.cjs <size> <in.svg> <out.png> [<size> <in.svg> <out.png> ...]
const { chromium } = require('playwright');
const fs = require('node:fs');

(async () => {
  const jobs = process.argv.slice(2);
  if (jobs.length === 0 || jobs.length % 3 !== 0) {
    console.error('usage: render.cjs <size> <in.svg> <out.png> [...]');
    process.exit(2);
  }
  const browser = await chromium.launch();
  for (let i = 0; i < jobs.length; i += 3) {
    const size = parseInt(jobs[i], 10);
    const svg = fs.readFileSync(jobs[i + 1], 'utf8')
      .replace('<svg ', `<svg style="display:block;width:${size}px;height:${size}px" `);
    const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    await page.screenshot({ path: jobs[i + 2], omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
    await page.close();
  }
  await browser.close();
})();
