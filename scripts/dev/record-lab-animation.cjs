// Grava docs/media/infra-lab.svg como vídeo (WebM, 1080x1080, 2 ciclos de 14 s)
// para o LinkedIn, que não aceita SVG. Usa o Playwright com o Chrome do sistema:
//   PW=<caminho>/node_modules/playwright node scripts/dev/record-lab-animation.cjs
const path = require('path');
const fs = require('fs');
const { chromium } = require(process.env.PW || 'playwright');

(async () => {
  const svg = path.resolve(__dirname, '../../docs/media/infra-lab.svg');
  const outDir = path.resolve(__dirname, '../../docs/media');
  const browser = await chromium.launch({ channel: 'chrome' });
  const ctx = await browser.newContext({
    viewport: { width: 1080, height: 1080 },
    recordVideo: { dir: outDir, size: { width: 1080, height: 1080 } },
  });
  const page = await ctx.newPage();
  await page.goto('file://' + svg);
  await page.evaluate(() => document.querySelector('svg').setCurrentTime(0));
  await page.waitForTimeout(28_000);
  const video = page.video();
  await ctx.close();
  await browser.close();
  const target = path.join(outDir, 'infra-lab.webm');
  fs.renameSync(await video.path(), target);
  console.log(target);
})();
