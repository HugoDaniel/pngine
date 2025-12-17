// @ts-check
import { test, expect } from '@playwright/test';
import { readFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import { join } from 'path';

/**
 * PNG Extraction Tests
 *
 * Tests the PNG bytecode extraction functionality to prevent regressions
 * in async handling and data processing.
 */

const PROJECT_ROOT = join(import.meta.dirname, '../..');
const TEST_PNGINE = join(PROJECT_ROOT, 'examples/simple_triangle.pngine');
const TEST_PNG_OUTPUT = join(PROJECT_ROOT, 'zig-out/web/test-triangle.png');

test.describe('PNG Bytecode Extraction', () => {

    test.beforeAll(async () => {
        // Generate a test PNG with embedded bytecode
        if (!existsSync(TEST_PNG_OUTPUT)) {
            try {
                execSync(`./zig-out/bin/pngine ${TEST_PNGINE} -o ${TEST_PNG_OUTPUT}`, {
                    cwd: PROJECT_ROOT,
                    stdio: 'pipe',
                });
            } catch (err) {
                console.warn('Could not generate test PNG:', err.message);
            }
        }
    });

    test('extractPngb returns a Promise that resolves to Uint8Array', async ({ page }) => {
        await page.goto('/');

        // Test in browser context that extractPngb returns correct type
        const result = await page.evaluate(async () => {
            const { extractPngb } = await import('./pngine-png.js');

            // Create a minimal valid PNG with pNGb chunk for testing
            // PNG signature + IHDR + pNGb chunk + IEND
            const pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

            // IHDR chunk (1x1 RGBA)
            const ihdrData = [
                0x00, 0x00, 0x00, 0x01, // width = 1
                0x00, 0x00, 0x00, 0x01, // height = 1
                0x08,                   // bit depth = 8
                0x06,                   // color type = RGBA
                0x00,                   // compression = deflate
                0x00,                   // filter = adaptive
                0x00,                   // interlace = none
            ];
            const ihdrCrc = 0x938A22F7; // Precomputed CRC

            // pNGb chunk with uncompressed PNGB bytecode (version 1, no compression)
            const pngbPayload = [
                0x01,       // version
                0x00,       // flags (no compression)
                // Minimal PNGB header
                0x50, 0x4E, 0x47, 0x42, // magic "PNGB"
                0x01, 0x00,             // version 1
                0x00, 0x00,             // flags
                0x10, 0x00, 0x00, 0x00, // string table offset = 16
                0x10, 0x00, 0x00, 0x00, // data section offset = 16
            ];

            // Calculate CRC for pNGb chunk (type + data)
            const pngbType = [0x70, 0x4E, 0x47, 0x62]; // 'pNGb'

            // Build minimal PNG
            const png = new Uint8Array([
                ...pngSignature,
                // IHDR chunk
                0x00, 0x00, 0x00, 0x0D, // length = 13
                0x49, 0x48, 0x44, 0x52, // type = 'IHDR'
                ...ihdrData,
                (ihdrCrc >> 24) & 0xFF,
                (ihdrCrc >> 16) & 0xFF,
                (ihdrCrc >> 8) & 0xFF,
                ihdrCrc & 0xFF,
                // pNGb chunk
                0x00, 0x00, 0x00, pngbPayload.length, // length
                ...pngbType,
                ...pngbPayload,
                0x00, 0x00, 0x00, 0x00, // CRC placeholder (browser ignores)
                // IEND chunk
                0x00, 0x00, 0x00, 0x00, // length = 0
                0x49, 0x45, 0x4E, 0x44, // type = 'IEND'
                0xAE, 0x42, 0x60, 0x82, // CRC
            ]);

            try {
                const result = extractPngb(png);

                // CRITICAL: Verify extractPngb returns a Promise
                const isPromise = result instanceof Promise;

                // Wait for the result
                const bytecode = await result;

                // Verify the resolved value is a Uint8Array
                const isUint8Array = bytecode instanceof Uint8Array;

                // Verify it has the slice method (the bug was bytecode.slice not being a function)
                const hasSlice = typeof bytecode.slice === 'function';

                return {
                    isPromise,
                    isUint8Array,
                    hasSlice,
                    length: bytecode.length,
                    magic: String.fromCharCode(...bytecode.slice(0, 4)),
                };
            } catch (err) {
                return { error: err.message };
            }
        });

        // Assertions
        expect(result.error).toBeUndefined();
        expect(result.isPromise).toBe(true);
        expect(result.isUint8Array).toBe(true);
        expect(result.hasSlice).toBe(true);
        expect(result.magic).toBe('PNGB');
    });

    test('hasPngb correctly detects embedded bytecode', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { hasPngb } = await import('./pngine-png.js');

            // PNG without pNGb chunk (just signature + IHDR + IEND)
            const pngWithout = new Uint8Array([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
                0x00, 0x00, 0x00, 0x0D, // IHDR length
                0x49, 0x48, 0x44, 0x52, // IHDR type
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
                0x08, 0x06, 0x00, 0x00, 0x00, // 8-bit RGBA
                0x1F, 0x15, 0xC4, 0x89, // CRC
                0x00, 0x00, 0x00, 0x00, // IEND length
                0x49, 0x45, 0x4E, 0x44, // IEND type
                0xAE, 0x42, 0x60, 0x82, // CRC
            ]);

            // PNG with pNGb chunk
            const pngWith = new Uint8Array([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
                0x00, 0x00, 0x00, 0x0D, // IHDR length
                0x49, 0x48, 0x44, 0x52, // IHDR type
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00,
                0x1F, 0x15, 0xC4, 0x89,
                0x00, 0x00, 0x00, 0x05, // pNGb length
                0x70, 0x4E, 0x47, 0x62, // pNGb type
                0x01, 0x00, 0x50, 0x4E, 0x47, // payload
                0x00, 0x00, 0x00, 0x00, // CRC
                0x00, 0x00, 0x00, 0x00,
                0x49, 0x45, 0x4E, 0x44,
                0xAE, 0x42, 0x60, 0x82,
            ]);

            return {
                withoutPngb: hasPngb(pngWithout),
                withPngb: hasPngb(pngWith),
            };
        });

        expect(result.withoutPngb).toBe(false);
        expect(result.withPngb).toBe(true);
    });

    test('getPngbInfo returns correct metadata', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { getPngbInfo } = await import('./pngine-png.js');

            // PNG with pNGb chunk (uncompressed)
            const png = new Uint8Array([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D, // IHDR
                0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00,
                0x1F, 0x15, 0xC4, 0x89,
                0x00, 0x00, 0x00, 0x12, // pNGb length = 18
                0x70, 0x4E, 0x47, 0x62, // pNGb type
                0x01,                   // version = 1
                0x00,                   // flags = 0 (uncompressed)
                // 16 bytes of payload
                0x50, 0x4E, 0x47, 0x42, 0x01, 0x00, 0x00, 0x00,
                0x10, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, // CRC
                0x00, 0x00, 0x00, 0x00,
                0x49, 0x45, 0x4E, 0x44,
                0xAE, 0x42, 0x60, 0x82,
            ]);

            return getPngbInfo(png);
        });

        expect(result).not.toBeNull();
        expect(result.version).toBe(1);
        expect(result.compressed).toBe(false);
        expect(result.payloadSize).toBe(16); // 18 - 2 (version + flags)
    });

    test('extractPngb throws on PNG without pNGb chunk', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { extractPngb } = await import('./pngine-png.js');

            const pngWithout = new Uint8Array([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D,
                0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00,
                0x1F, 0x15, 0xC4, 0x89,
                0x00, 0x00, 0x00, 0x00,
                0x49, 0x45, 0x4E, 0x44,
                0xAE, 0x42, 0x60, 0x82,
            ]);

            try {
                await extractPngb(pngWithout);
                return { threw: false };
            } catch (err) {
                return { threw: true, message: err.message };
            }
        });

        expect(result.threw).toBe(true);
        expect(result.message).toContain('No pNGb chunk');
    });

});

test.describe('PNG Tab UI', () => {

    test.beforeAll(async () => {
        // Ensure test PNG exists
        if (!existsSync(TEST_PNG_OUTPUT)) {
            try {
                execSync(`./zig-out/bin/pngine ${TEST_PNGINE} -o ${TEST_PNG_OUTPUT}`, {
                    cwd: PROJECT_ROOT,
                    stdio: 'pipe',
                });
            } catch (err) {
                console.warn('Could not generate test PNG:', err.message);
            }
        }
    });

    test('PNG tab shows correct info for PNG with bytecode', async ({ page }) => {
        test.skip(!existsSync(TEST_PNG_OUTPUT), 'Test PNG not available');

        await page.goto('/');

        // Switch to PNG tab
        await page.click('.tab[data-tab="png"]');
        await expect(page.locator('#png-tab')).toHaveClass(/active/);

        // Upload the test PNG
        const fileInput = page.locator('#png-file');
        await fileInput.setInputFiles(TEST_PNG_OUTPUT);

        // Wait for processing
        await page.waitForFunction(() => {
            const info = document.getElementById('png-info');
            return info && info.textContent.includes('Bytecode');
        }, { timeout: 5000 });

        // Verify badge shows bytecode detected
        const pngInfo = page.locator('#png-info');
        await expect(pngInfo).toContainText('Has Embedded Bytecode');
        await expect(pngInfo).toContainText('PNGB');

        // Note: Run button may be disabled if WebGPU isn't available (headless mode)
        // The important thing is that extraction worked and info is displayed correctly
    });

    test('PNG tab shows warning for PNG without bytecode', async ({ page }) => {
        await page.goto('/');

        // Switch to PNG tab
        await page.click('.tab[data-tab="png"]');

        // Create a minimal PNG without pNGb chunk in the browser
        await page.evaluate(async () => {
            const pngWithout = new Uint8Array([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D,
                0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00,
                0x1F, 0x15, 0xC4, 0x89,
                0x00, 0x00, 0x00, 0x0A, // IDAT
                0x49, 0x44, 0x41, 0x54,
                0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
                0x0D, 0x0A, 0x2D, 0xB4,
                0x00, 0x00, 0x00, 0x00,
                0x49, 0x45, 0x4E, 0x44,
                0xAE, 0x42, 0x60, 0x82,
            ]);

            // Create a file and trigger the file input
            const blob = new Blob([pngWithout], { type: 'image/png' });
            const file = new File([blob], 'test-no-bytecode.png', { type: 'image/png' });

            const dataTransfer = new DataTransfer();
            dataTransfer.items.add(file);

            const fileInput = document.getElementById('png-file');
            fileInput.files = dataTransfer.files;
            fileInput.dispatchEvent(new Event('change', { bubbles: true }));
        });

        // Wait for processing
        await page.waitForFunction(() => {
            const info = document.getElementById('png-info');
            return info && info.textContent.includes('No Embedded Bytecode');
        }, { timeout: 5000 });

        // Verify badge shows no bytecode
        const pngInfo = page.locator('#png-info');
        await expect(pngInfo).toContainText('No Embedded Bytecode');

        // Verify Run button is disabled
        await expect(page.locator('#run-png-btn')).toBeDisabled();
    });

    test('extractPngb result is awaited correctly (regression test)', async ({ page }) => {
        test.skip(!existsSync(TEST_PNG_OUTPUT), 'Test PNG not available');

        await page.goto('/');

        // Switch to PNG tab
        await page.click('.tab[data-tab="png"]');

        // Upload the test PNG
        const fileInput = page.locator('#png-file');
        await fileInput.setInputFiles(TEST_PNG_OUTPUT);

        // Wait for processing to complete
        await page.waitForFunction(() => {
            const info = document.getElementById('png-info');
            return info && (
                info.textContent.includes('Has Embedded Bytecode') ||
                info.textContent.includes('Extraction Error')
            );
        }, { timeout: 5000 });

        // CRITICAL: Verify no "slice is not a function" error
        const pngInfo = page.locator('#png-info');
        const infoText = await pngInfo.textContent();

        // If there's an extraction error, it should NOT be about slice
        if (infoText.includes('Extraction Error')) {
            expect(infoText).not.toContain('slice is not a function');
            expect(infoText).not.toContain('is not a function');
        } else {
            // Success case - verify bytecode info is displayed
            expect(infoText).toContain('Magic: PNGB');
        }
    });

});
