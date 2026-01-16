// @ts-check
import { test, expect } from '@playwright/test';
import { readFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import { join } from 'path';

/**
 * PNG Extraction Tests
 *
 * Tests the PNG bytecode extraction functionality using the new _extract.js API.
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

    test('extractBytecode returns a Promise that resolves to Uint8Array', async ({ page }) => {
        await page.goto('/');

        // Test in browser context that extractBytecode returns correct type
        const result = await page.evaluate(async () => {
            const { extractBytecode } = await import('./_extract.js');

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
                const result = extractBytecode(png);

                // CRITICAL: Verify extractBytecode returns a Promise
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

    test('isPng and isPngb correctly detect formats', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { isPng, isPngb } = await import('./_extract.js');

            // PNG without pNGb chunk (just signature + IHDR + IEND)
            const pngData = new Uint8Array([
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

            // PNGB bytecode (raw)
            const pngbData = new Uint8Array([
                0x50, 0x4E, 0x47, 0x42, // magic "PNGB"
                0x01, 0x00, 0x00, 0x00, // version, flags
                0x10, 0x00, 0x00, 0x00, // string table offset
                0x10, 0x00, 0x00, 0x00, // data section offset
            ]);

            // Random data (neither)
            const randomData = new Uint8Array([0x01, 0x02, 0x03, 0x04]);

            return {
                pngIsPng: isPng(pngData),
                pngIsPngb: isPngb(pngData),
                pngbIsPng: isPng(pngbData),
                pngbIsPngb: isPngb(pngbData),
                randomIsPng: isPng(randomData),
                randomIsPngb: isPngb(randomData),
            };
        });

        expect(result.pngIsPng).toBe(true);
        expect(result.pngIsPngb).toBe(false);
        expect(result.pngbIsPng).toBe(false);
        expect(result.pngbIsPngb).toBe(true);
        expect(result.randomIsPng).toBe(false);
        expect(result.randomIsPngb).toBe(false);
    });

    test('detectFormat identifies file types correctly', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { detectFormat } = await import('./_extract.js');

            // PNG data
            const pngData = new Uint8Array([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            ]);

            // PNGB bytecode
            const pngbData = new Uint8Array([
                0x50, 0x4E, 0x47, 0x42, // PNGB magic
            ]);

            // ZIP data
            const zipData = new Uint8Array([
                0x50, 0x4B, 0x03, 0x04, // ZIP signature
            ]);

            // Random data
            const randomData = new Uint8Array([0x01, 0x02, 0x03, 0x04]);

            return {
                png: detectFormat(pngData),
                pngb: detectFormat(pngbData),
                zip: detectFormat(zipData),
                random: detectFormat(randomData),
            };
        });

        expect(result.png).toBe('png');
        expect(result.pngb).toBe('pngb');
        expect(result.zip).toBe('zip');
        expect(result.random).toBe(null);
    });

    test('extractBytecode throws on PNG without pNGb chunk', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { extractBytecode } = await import('./_extract.js');

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
                await extractBytecode(pngWithout);
                return { threw: false };
            } catch (err) {
                return { threw: true, message: err.message };
            }
        });

        expect(result.threw).toBe(true);
        expect(result.message).toContain('pNGb');
    });

    test('extractBytecode passes through raw PNGB bytecode', async ({ page }) => {
        await page.goto('/');

        const result = await page.evaluate(async () => {
            const { extractBytecode } = await import('./_extract.js');

            // Raw PNGB bytecode (no PNG container)
            const pngbData = new Uint8Array([
                0x50, 0x4E, 0x47, 0x42, // magic "PNGB"
                0x01, 0x00,             // version 1
                0x00, 0x00,             // flags
                0x10, 0x00, 0x00, 0x00, // string table offset = 16
                0x10, 0x00, 0x00, 0x00, // data section offset = 16
            ]);

            try {
                const result = await extractBytecode(pngbData);
                return {
                    length: result.length,
                    magic: String.fromCharCode(...result.slice(0, 4)),
                };
            } catch (err) {
                return { error: err.message };
            }
        });

        expect(result.error).toBeUndefined();
        expect(result.length).toBe(16);
        expect(result.magic).toBe('PNGB');
    });

});

test.describe('Playground Page UI', () => {

    test('page loads and shows ready status', async ({ page }) => {
        await page.goto('/');

        // Check status shows ready
        const status = page.locator('#status');
        await expect(status).toContainText('Ready');
    });

    test('example links are present', async ({ page }) => {
        await page.goto('/');

        // Check example links exist
        const triangleLink = page.locator('a[data-url*="simple_triangle"]');
        const cubeLink = page.locator('a[data-url*="rotating_cube"]');

        await expect(triangleLink).toBeVisible();
        await expect(cubeLink).toBeVisible();
    });

    test('drop zone accepts file input', async ({ page }) => {
        await page.goto('/');

        // Verify file input is present
        const fileInput = page.locator('#file-input');
        await expect(fileInput).toBeAttached();
    });

});
