// Browser-level smoke: verify the Flutter engine actually renders a view,
// not only that the development server returns its bootstrap HTML.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(path.join(
  process.env.RUNNER_TEMP,
  'breezze-browser',
  'node_modules',
  'playwright-core',
));

async function main() {
  const browser = await chromium.launch({
    executablePath: process.env.BREEZZE_BROWSER,
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--use-angle=swiftshader',
      '--enable-unsafe-swiftshader',
    ],
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 1,
      reducedMotion: 'reduce',
    });
    const errors = [];
    const consoleErrors = [];
    const failedRequests = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {
      if (message.type() === 'error') consoleErrors.push(message.text());
    });
    page.on('requestfailed', request => {
      failedRequests.push({
        url: request.url(),
        failure: request.failure()?.errorText,
      });
    });
    const shot = path.join(process.env.RUNNER_TEMP, 'breezze-mobile-preview.png');
    await page.goto('http://127.0.0.1:8080/', {
      waitUntil: 'domcontentloaded',
      timeout: 90000,
    });

    try {
      await page.waitForFunction(
        () => {
          const host = document.querySelector('flutter-view, flt-glass-pane');
          const rendered = document.querySelector('canvas, flt-scene-host');
          return host !== null && rendered !== null;
        },
        null,
        { timeout: 60000 },
      );
    } catch (error) {
      const details = await page.evaluate(() => ({
        title: document.title,
        readyState: document.readyState,
        body: document.body.innerHTML.slice(0, 4000),
        canvasCount: document.querySelectorAll('canvas').length,
        flutterHostCount: document.querySelectorAll('flutter-view, flt-glass-pane').length,
        scriptUrls: [...document.querySelectorAll('script')].map(s => s.src),
      }));
      console.error('Breezze browser DOM diagnostics:', JSON.stringify(details));
      console.error('Breezze browser JS errors:', JSON.stringify(errors));
      console.error('Breezze browser console errors:', JSON.stringify(consoleErrors));
      console.error('Breezze browser failed requests:', JSON.stringify(failedRequests));
      await page.screenshot({ path: shot, fullPage: true });
      throw error;
    }
    await page.waitForTimeout(2500);
    await page.screenshot({ path: shot, fullPage: true });
    const size = fs.statSync(shot).size;
    assert.ok(size > 5000, 'Browser screenshot is unexpectedly small');
    assert.ok((await page.title()).includes('Breezze'), 'Incorrect page title');
    assert.deepEqual(errors, [], 'Browser emitted uncaught JavaScript errors');

    console.log('Flutter rendered in headless Chromium; mobile screenshot:', shot);
    console.log('Screenshot size:', size, 'bytes');
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
