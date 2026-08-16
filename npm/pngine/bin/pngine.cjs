#!/usr/bin/env node

/**
 * PNGine CLI Wrapper
 *
 * Finds and executes the platform-specific native binary.
 * Native binaries are distributed in separate optional packages.
 */

const { spawn } = require('child_process');
const path = require('path');

// Platform to package mapping
const PLATFORMS = {
  'darwin-arm64': '@pngine/darwin-arm64',
  'darwin-x64': '@pngine/darwin-x64',
  'linux-x64': '@pngine/linux-x64',
  'linux-arm64': '@pngine/linux-arm64',
  'win32-x64': '@pngine/win32-x64',
  'win32-arm64': '@pngine/win32-arm64',
};

/**
 * Get the path to the native binary for the current platform.
 * @returns {string} Path to the binary
 */
function getBinaryPath() {
  const platform = `${process.platform}-${process.arch}`;
  const pkg = PLATFORMS[platform];

  if (!pkg) {
    console.error(`Error: Unsupported platform: ${platform}`);
    console.error('');
    console.error('Supported platforms:');
    console.error('  - macOS ARM64 (Apple Silicon)');
    console.error('  - macOS x64 (Intel)');
    console.error('  - Linux x64');
    console.error('  - Linux ARM64');
    console.error('  - Windows x64');
    console.error('  - Windows ARM64');
    process.exit(1);
  }

  try {
    // Find the platform package
    const pkgPath = require.resolve(`${pkg}/package.json`);
    const binName = process.platform === 'win32' ? 'pngine.exe' : 'pngine';
    return path.join(path.dirname(pkgPath), 'bin', binName);
  } catch (err) {
    console.error(`Error: Platform package ${pkg} is not installed.`);
    console.error('');
    console.error('This usually means npm failed to install the optional dependency.');
    console.error('Try reinstalling:');
    console.error('');
    console.error('  npm install pngine');
    console.error('');
    console.error('Or install the platform package directly:');
    console.error('');
    console.error(`  npm install ${pkg}`);
    process.exit(1);
  }
}

// Get the binary path
const binaryPath = getBinaryPath();

// Spawn the native binary with all arguments
const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: 'inherit',
  windowsHide: true,
});

// Forward signals
process.on('SIGINT', () => child.kill('SIGINT'));
process.on('SIGTERM', () => child.kill('SIGTERM'));

// Exit with the same code as the child process
child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});

child.on('error', (err) => {
  console.error(`Error executing pngine: ${err.message}`);
  process.exit(1);
});
