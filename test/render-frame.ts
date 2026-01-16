/**
 * Render Frame Script - Browser-based shader frame capture
 *
 * Compiles a .pngine file and renders it via headless browser,
 * capturing the output as a PNG file.
 *
 * Usage:
 *   npx tsx test/render-frame.ts <input.pngine> [options]
 *
 * Options:
 *   -o, --output <path>   Output PNG path (default: <input>.png)
 *   -s, --size <WxH>      Canvas dimensions (default: 512x512)
 *   -t, --time <seconds>  Animation time (default: 0.0)
 *   --wait <ms>           Wait time for rendering (default: 1000)
 *   --no-headless         Show browser window
 *
 * Example:
 *   npx tsx test/render-frame.ts examples/pngine_logo.pngine -o output.png -s 512x512
 */

import { chromium } from 'playwright';
import { execSync } from 'child_process';
import { writeFileSync, existsSync } from 'fs';
import { basename, dirname, join } from 'path';

interface Options {
  input: string;
  output: string;
  width: number;
  height: number;
  time: number;
  wait: number;
  headless: boolean;
}

function parseArgs(args: string[]): Options | null {
  const opts: Options = {
    input: '',
    output: '',
    width: 512,
    height: 512,
    time: 0.0,
    wait: 1000,
    headless: true,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '-o' || arg === '--output') {
      opts.output = args[++i];
    } else if (arg === '-s' || arg === '--size') {
      const size = args[++i];
      const [w, h] = size.split('x').map(Number);
      if (w && h) {
        opts.width = w;
        opts.height = h;
      }
    } else if (arg === '-t' || arg === '--time') {
      opts.time = parseFloat(args[++i]);
    } else if (arg === '--wait') {
      opts.wait = parseInt(args[++i]);
    } else if (arg === '--no-headless') {
      opts.headless = false;
    } else if (!arg.startsWith('-')) {
      opts.input = arg;
    }
  }

  if (!opts.input) {
    return null;
  }

  // Derive output path
  if (!opts.output) {
    const name = basename(opts.input, '.pngine');
    opts.output = join(dirname(opts.input) || '.', `${name}.png`);
  }

  return opts;
}

async function main() {
  const args = process.argv.slice(2);
  const opts = parseArgs(args);

  if (!opts) {
    console.error('Usage: npx tsx test/render-frame.ts <input.pngine> [options]');
    console.error('');
    console.error('Options:');
    console.error('  -o, --output <path>   Output PNG path');
    console.error('  -s, --size <WxH>      Canvas dimensions (default: 512x512)');
    console.error('  -t, --time <seconds>  Animation time (default: 0.0)');
    console.error('  --wait <ms>           Wait time for rendering (default: 1000)');
    console.error('  --no-headless         Show browser window');
    process.exit(1);
  }

  if (!existsSync(opts.input)) {
    console.error(`Error: Input file not found: ${opts.input}`);
    process.exit(1);
  }

  console.log(`Compiling ${opts.input}...`);

  // Compile the shader
  const pngPath = join('zig-out/playground/', basename(opts.input, '.pngine') + '.png');
  try {
    execSync(`./zig-out/bin/pngine ${opts.input} -o ${pngPath}`, { stdio: 'inherit' });
  } catch (err) {
    console.error('Compilation failed');
    process.exit(1);
  }

  // Create a temporary HTML page for rendering
  const htmlContent = `
<!DOCTYPE html>
<html>
<head>
  <title>Render Frame</title>
  <style>
    body { margin: 0; padding: 0; background: #000; }
    canvas { display: block; }
  </style>
</head>
<body>
  <canvas id="canvas" width="${opts.width}" height="${opts.height}"></canvas>
  <script type="module">
    import { pngine, play, draw } from './pngine.js';

    const canvas = document.getElementById('canvas');

    async function init() {
      try {
        const p = await pngine('${basename(pngPath)}', { canvas, debug: false });

        // Set time if specified
        ${opts.time > 0 ? `draw(p, { time: ${opts.time} });` : 'draw(p, { time: 0 });'}

        // Signal render complete
        console.log('[RenderFrame] Complete');
      } catch (err) {
        console.error('[RenderFrame] Error:', err.message);
      }
    }

    init();
  </script>
</body>
</html>
`;

  const tempHtmlPath = join('zig-out/playground/', 'render-frame-temp.html');
  writeFileSync(tempHtmlPath, htmlContent);

  console.log(`Rendering at ${opts.width}x${opts.height}, t=${opts.time}...`);

  // Launch browser and capture screenshot
  const browser = await chromium.launch({
    headless: opts.headless,
    args: [
      '--enable-unsafe-webgpu',
      '--enable-features=Vulkan,UseSkiaRenderer',
      '--use-angle=vulkan',
      '--disable-gpu-sandbox',
      '--use-gl=angle',
      '--ignore-gpu-blocklist',
    ],
  });

  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    // Wait for render complete message
    let renderComplete = false;
    page.on('console', (msg) => {
      const text = msg.text();
      if (text.includes('[RenderFrame] Complete')) {
        renderComplete = true;
      } else if (text.includes('[RenderFrame] Error')) {
        console.error(text);
      }
    });

    // Navigate to the temp HTML page (served by Vite)
    await page.goto(`http://localhost:5173/render-frame-temp.html`, { timeout: 30000 });

    // Wait for render or timeout
    const deadline = Date.now() + 10000;
    while (!renderComplete && Date.now() < deadline) {
      await page.waitForTimeout(100);
    }

    // Extra wait for GPU to finish
    await page.waitForTimeout(opts.wait);

    // Capture screenshot of canvas
    const canvas = await page.$('#canvas');
    if (canvas) {
      const buffer = await canvas.screenshot({ type: 'png' });
      writeFileSync(opts.output, buffer);
      console.log(`Saved: ${opts.output} (${opts.width}x${opts.height})`);
    } else {
      console.error('Error: Canvas not found');
      process.exit(1);
    }
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error('Error:', err.message);
  process.exit(1);
});
