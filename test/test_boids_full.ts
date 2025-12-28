import { chromium } from 'playwright';
import * as fs from 'fs';

async function main() {
  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const contexts = browser.contexts();

  if (contexts.length === 0) {
    console.log('No contexts found');
    return;
  }

  // Find or create boids test page
  let testPage = null;
  for (const ctx of contexts) {
    for (const page of ctx.pages()) {
      if (page.url().includes('test-boids')) {
        testPage = page;
        break;
      }
    }
  }

  if (!testPage) {
    const ctx = contexts[0];
    const pages = ctx.pages();
    if (pages.length > 0) {
      testPage = pages[0];
      await testPage.goto('http://localhost:5173/test-boids.html');
    }
  }

  if (!testPage) {
    console.log('Could not get test page');
    return;
  }

  console.log('Testing:', testPage.url());

  const logs: string[] = [];
  const errors: string[] = [];

  testPage.on('console', msg => {
    const text = '[' + msg.type() + '] ' + msg.text();
    logs.push(text);
    if (msg.type() === 'error') {
      errors.push(msg.text());
    }
  });

  await testPage.reload();
  await testPage.waitForTimeout(3000);

  console.log('\n=== Errors (' + errors.length + ') ===');
  for (const err of errors.slice(0, 10)) {
    console.log(err);
  }

  console.log('\n=== Key Logs (first 30) ===');
  let count = 0;
  for (const log of logs) {
    if (log.includes('[GPU]') && count < 30) {
      console.log(log);
      count++;
    }
  }

  // Check for instanced draw
  const hasInstancedDraw = logs.some(l => l.includes('inst=2048') || l.includes('instanceCount'));
  console.log('\n=== Instanced Draw: ' + (hasInstancedDraw ? 'YES' : 'NO') + ' ===');

  const screenshot = await testPage.screenshot();
  fs.writeFileSync('/tmp/boids_full_screenshot.png', screenshot);
  console.log('\nScreenshot saved to /tmp/boids_full_screenshot.png');

  await browser.close();
}

main().catch(console.error);
