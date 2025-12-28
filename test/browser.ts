/**
 * Browser Console Capture Script for WebGPU Development
 *
 * Launches Chromium with WebGPU flags, captures console output,
 * and returns structured JSON for LLM iteration.
 *
 * Usage:
 *   npx tsx test/browser.ts <url> [options]
 *
 * Options:
 *   --screenshot      Capture screenshot (base64 in output)
 *   --wait <ms>       Wait time after load (default: 2000)
 *   --timeout <ms>    Max total time (default: 30000)
 *   --no-headless     Show browser window
 *   --wait-for <text> Wait for specific console message
 */

import { chromium, type ConsoleMessage } from 'playwright';

interface LogEntry {
  time: number;
  level: string;
  prefix: string | null;
  message: string;
}

interface ErrorEntry {
  time: number;
  type: string;
  message: string;
}

interface Result {
  success: boolean;
  url: string;
  duration_ms: number;
  webgpu_available: boolean;
  logs: LogEntry[];
  errors: ErrorEntry[];
  warnings: LogEntry[];
  summary: {
    total_logs: number;
    gpu_commands: number;
    draw_calls: number;
    dispatch_calls: number;
    error_count: number;
    warning_count: number;
  };
  screenshot: string | null;
}

function parseArgs(args: string[]) {
  const opts = {
    url: '',
    screenshot: false,
    wait: 2000,
    timeout: 30000,
    headless: true,
    waitFor: null as string | null,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--screenshot') opts.screenshot = true;
    else if (arg === '--wait' && args[i + 1]) opts.wait = parseInt(args[++i]);
    else if (arg === '--timeout' && args[i + 1]) opts.timeout = parseInt(args[++i]);
    else if (arg === '--headless') opts.headless = true;
    else if (arg === '--no-headless') opts.headless = false;
    else if (arg === '--wait-for' && args[i + 1]) opts.waitFor = args[++i];
    else if (!arg.startsWith('-')) opts.url = arg;
  }

  return opts;
}

function extractPrefix(msg: string): { prefix: string | null; message: string } {
  const match = msg.match(/^\[(\w+)\]\s*/);
  if (match) {
    return { prefix: `[${match[1]}]`, message: msg.slice(match[0].length) };
  }
  return { prefix: null, message: msg };
}

async function main() {
  const args = process.argv.slice(2);
  const opts = parseArgs(args);

  if (!opts.url) {
    console.error('Usage: npx tsx test/browser.ts <url> [--screenshot] [--wait <ms>] [--timeout <ms>]');
    process.exit(1);
  }

  const startTime = Date.now();
  const logs: LogEntry[] = [];
  const errors: ErrorEntry[] = [];
  const warnings: LogEntry[] = [];
  let webgpuAvailable = false;
  let waitForResolved = !opts.waitFor;

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

  const context = await browser.newContext();
  const page = await context.newPage();

  // Capture console messages
  page.on('console', (msg: ConsoleMessage) => {
    const time = Date.now() - startTime;
    const text = msg.text();
    const { prefix, message } = extractPrefix(text);
    const level = msg.type();

    if (level === 'error') {
      errors.push({ time, type: 'console.error', message: text });
    } else if (level === 'warning') {
      warnings.push({ time, level, prefix, message });
    } else {
      logs.push({ time, level, prefix, message });
    }

    // Check for wait-for condition
    if (opts.waitFor && text.includes(opts.waitFor)) {
      waitForResolved = true;
    }
  });

  // Capture page errors (uncaught exceptions)
  page.on('pageerror', (err) => {
    const time = Date.now() - startTime;
    errors.push({ time, type: 'page_error', message: err.message });
  });

  try {
    await page.goto(opts.url, { timeout: opts.timeout });

    // Check WebGPU availability
    webgpuAvailable = await page.evaluate(() => {
      return typeof navigator !== 'undefined' && 'gpu' in navigator;
    });

    // Wait for condition or timeout
    if (opts.waitFor) {
      const deadline = Date.now() + opts.timeout;
      while (!waitForResolved && Date.now() < deadline) {
        await page.waitForTimeout(100);
      }
    } else {
      await page.waitForTimeout(opts.wait);
    }

    // Capture screenshot if requested
    let screenshot: string | null = null;
    if (opts.screenshot) {
      const buffer = await page.screenshot({ type: 'png' });
      screenshot = buffer.toString('base64');
    }

    // Build summary
    const gpuLogs = logs.filter(l => l.prefix === '[GPU]');
    const drawCalls = gpuLogs.filter(l => l.message.includes('draw(')).length;
    const dispatchCalls = gpuLogs.filter(l => l.message.includes('dispatch(')).length;

    const result: Result = {
      success: errors.length === 0,
      url: opts.url,
      duration_ms: Date.now() - startTime,
      webgpu_available: webgpuAvailable,
      logs,
      errors,
      warnings,
      summary: {
        total_logs: logs.length,
        gpu_commands: gpuLogs.length,
        draw_calls: drawCalls,
        dispatch_calls: dispatchCalls,
        error_count: errors.length,
        warning_count: warnings.length,
      },
      screenshot,
    };

    console.log(JSON.stringify(result, null, 2));
  } catch (err) {
    const result: Result = {
      success: false,
      url: opts.url,
      duration_ms: Date.now() - startTime,
      webgpu_available: webgpuAvailable,
      logs,
      errors: [...errors, { time: Date.now() - startTime, type: 'script_error', message: String(err) }],
      warnings,
      summary: {
        total_logs: logs.length,
        gpu_commands: 0,
        draw_calls: 0,
        dispatch_calls: 0,
        error_count: errors.length + 1,
        warning_count: warnings.length,
      },
      screenshot: null,
    };
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await browser.close();
  }
}

main();
