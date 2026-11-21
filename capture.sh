#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$PROJECT_DIR"
: "${CAPTURE_URL:?Set CAPTURE_URL to the exact preview URL}"
: "${CAPTURE_DIR:?Set CAPTURE_DIR to the evidence output directory}"

/usr/bin/time -p mkdir -p "$CAPTURE_DIR"
/usr/bin/time -p node --input-type=commonjs <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const started = Date.now();
const captureDir = process.env.CAPTURE_DIR;
const url = process.env.CAPTURE_URL;
const runtime = path.join(process.env.HOME, '.local/share/omgithub-playwright');
const load = createRequire(path.join(runtime, 'package.json'));
let browser;
let result = 0;
const timed = async (label, action) => {
  const t = Date.now();
  try { return await action(); }
  finally { console.log(`${label}: real ${((Date.now() - t) / 1000).toFixed(2)}s`); }
};
const fail = (message, code = 1) => { const error = new Error(message); error.exitCode = code; throw error; };
const transient = error => { error.exitCode = 75; throw error; };

(async () => {
  let chromium, config;
  try {
    ({ chromium } = load('playwright'));
    config = JSON.parse(fs.readFileSync(path.join(runtime, process.platform === 'darwin' ? 'metal.json' : 'linux.json'), 'utf8'));
    if (process.platform === 'linux') process.env.DISPLAY ||= ':' + fs.readFileSync(path.join(runtime, 'display'), 'utf8').trim();
  } catch (error) {
    console.error(`Browser setup failed: ${error.message}`);
    fail('Browser infrastructure unavailable.', 75);
  }
  browser = await timed('browser launch', () => chromium.launch({ ...config.browser.launchOptions, timeout: 30000 }).catch(transient));
  const origin = new URL(url).origin;
  for (const [name, width, height] of [['desktop', 1280, 900], ['mobile', 390, 844]]) {
    const page = await timed(`${name} page creation`, () => browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 }).catch(transient));
    page.setDefaultTimeout(20000);
    const pageErrors = [];
    const badResponses = [];
    page.on('pageerror', error => pageErrors.push(error.message));
    page.on('response', response => {
      let responseUrl;
      try { responseUrl = new URL(response.url()); } catch { return; }
      if (responseUrl.origin === origin && response.status() >= 400 && !responseUrl.pathname.endsWith('/favicon.ico')) {
        badResponses.push(`HTTP ${response.status()} ${response.url()}`);
      }
    });
    const response = await timed(`${name} navigation`, () => page.goto(url, { waitUntil: 'load', timeout: 45000 }).catch(transient));
    if (!response) fail(`${name}: navigation returned no response.`, 75);
    if (!response.ok()) fail(`${name}: preview returned HTTP ${response.status()}.`, response.status() >= 500 || response.status() === 429 ? 75 : 1);
    await timed(`${name} rendered-content wait`, async () => {
      try {
        await page.locator('#game-canvas').waitFor({ state: 'visible', timeout: 20000 });
        await page.locator('h1').waitFor({ state: 'visible', timeout: 5000 });
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        await page.waitForTimeout(500);
        const rendered = await page.evaluate(() => {
          const canvas = document.querySelector('#game-canvas');
          if (!canvas || canvas.width < 100 || canvas.height < 100) return false;
          const context = canvas.getContext('2d');
          if (!context) return false;
          const colors = new Set();
          for (let y = 10; y < canvas.height; y += 37) {
            for (let x = 10; x < canvas.width; x += 37) {
              const pixel = context.getImageData(x, y, 1, 1).data;
              colors.add(`${pixel[0]},${pixel[1]},${pixel[2]},${pixel[3]}`);
            }
          }
          return colors.size > 4 && document.body.innerText.includes('Flappy');
        });
        if (!rendered) fail(`${name}: game content did not render correctly.`);
      } catch (error) {
        if (error.exitCode) throw error;
        fail(`${name}: game content did not render: ${error.message}`);
      }
    });
    if (pageErrors.length) fail(`${name}: browser script error: ${pageErrors.join('; ')}`);
    if (badResponses.length) fail(`${name}: failed app request: ${badResponses.join('; ')}`);
    await timed(`${name} screenshot`, () => page.screenshot({ path: path.join(captureDir, `final-${name}.png`), fullPage: false, timeout: 30000 }).catch(error => {
      if (error.name === 'TimeoutError' || !browser.isConnected()) transient(error);
      throw error;
    }));
    await timed(`${name} page close`, () => page.close());
  }
})().catch(error => {
  result = error.exitCode || 1;
  console.error(error.stack || error);
}).finally(async () => {
  if (browser) await timed('browser close', () => browser.close().catch(error => { result ||= 75; console.error(error.message); }));
  console.log(`capture total: real ${((Date.now() - started) / 1000).toFixed(2)}s`);
  process.exitCode = result;
});
NODE
