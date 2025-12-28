import { chromium } from 'playwright';
import * as fs from 'fs';

async function main() {
  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const contexts = browser.contexts();
  const ctx = contexts[0];
  const pages = ctx.pages();
  const testPage = pages[0];

  // Navigate away first to force reload
  await testPage.goto('about:blank');
  await testPage.waitForTimeout(500);
  
  // Clear cache and navigate
  await testPage.goto('http://localhost:5173/test-boids.html', { waitUntil: 'networkidle' });

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

  // Hard reload
  await testPage.reload({ waitUntil: 'networkidle' });
  await testPage.waitForTimeout(3000);

  console.log('\n=== Errors (' + errors.length + ') ===');
  for (const err of errors.slice(0, 5)) {
    console.log(err);
  }

  console.log('\n=== Init Logs ===');
  for (const log of logs.slice(0, 50)) {
    if (log.includes('Execute:') || log.includes('createBuffer') || log.includes('draw(')) {
      console.log(log);
    }
  }

  const screenshot = await testPage.screenshot();
  fs.writeFileSync('/tmp/boids_full_screenshot.png', screenshot);
  console.log('\nScreenshot saved');

  await browser.close();
}

main().catch(console.error);
