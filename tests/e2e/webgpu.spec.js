// @ts-check
import { test, expect } from '@playwright/test';

/**
 * PNGine WebGPU E2E Tests
 *
 * Tests real WebGPU rendering in a browser environment.
 * Requires Chrome with WebGPU support.
 *
 * NOTE: Headless Chrome has limited WebGPU support. These tests may fail
 * in headless mode. Run with --headed flag for full WebGPU testing:
 *   npx playwright test --headed
 */

/**
 * Check if WebGPU initialized successfully.
 * Returns true if ready, false if initialization failed.
 */
async function waitForInit(page, timeout = 10000) {
    try {
        await page.waitForFunction(() => {
            const status = document.getElementById('status');
            if (!status) return false;
            return status.textContent.includes('Ready') ||
                   status.textContent.includes('failed') ||
                   status.textContent.includes('not supported');
        }, { timeout });

        const status = await page.locator('#status').textContent();
        return status.includes('Ready');
    } catch {
        return false;
    }
}

test.describe('PNGine WebGPU', () => {

    test.beforeEach(async ({ page }) => {
        // Navigate to the demo page
        await page.goto('/');
    });

    test('page loads correctly', async ({ page }) => {
        // Verify the page structure is correct (works without WebGPU)
        await expect(page.locator('h1')).toHaveText('PNGine WebGPU Demo');
        await expect(page.locator('#source')).toBeVisible();
        await expect(page.locator('#canvas')).toBeVisible();
        await expect(page.locator('#run-btn')).toBeVisible();
        await expect(page.locator('#clear-btn')).toBeVisible();
    });

    test('initializes WebGPU when available', async ({ page }) => {
        const isReady = await waitForInit(page);

        if (isReady) {
            // WebGPU initialized successfully
            const status = page.locator('#status');
            await expect(status).toHaveText('Ready');
            await expect(status).toHaveClass(/success/);
            await expect(page.locator('#run-btn')).toBeEnabled();
        } else {
            // WebGPU not available (headless mode) - skip gracefully
            test.skip(true, 'WebGPU not available in this environment');
        }
    });

    test('compiles and renders simple triangle', async ({ page }) => {
        const isReady = await waitForInit(page);
        test.skip(!isReady, 'WebGPU not available');

        // Click run button
        await page.click('#run-btn');

        // Wait for execution to complete
        await page.waitForFunction(() => {
            const status = document.getElementById('status');
            return status && status.textContent.includes('Done');
        }, { timeout: 5000 });

        // Verify success status
        const status = page.locator('#status');
        await expect(status).toContainText('Done');
        await expect(status).toHaveClass(/success/);

        // Take screenshot of canvas for visual verification
        const canvas = page.locator('#canvas');
        await expect(canvas).toHaveScreenshot('triangle.png', {
            maxDiffPixels: 100, // Allow small differences for anti-aliasing
        });
    });

    test('handles compilation errors gracefully', async ({ page }) => {
        const isReady = await waitForInit(page);
        test.skip(!isReady, 'WebGPU not available');

        // Enter invalid PBSF source
        const textarea = page.locator('#source');
        await textarea.fill('(invalid syntax here');

        // Click run
        await page.click('#run-btn');

        // Verify error status
        const status = page.locator('#status');
        await expect(status).toContainText('Error');
        await expect(status).toHaveClass(/error/);
    });

    test('clears canvas', async ({ page }) => {
        const isReady = await waitForInit(page);
        test.skip(!isReady, 'WebGPU not available');

        // First render something
        await page.click('#run-btn');
        await page.waitForFunction(() => {
            const status = document.getElementById('status');
            return status && status.textContent.includes('Done');
        });

        // Then clear
        await page.click('#clear-btn');

        // Verify cleared status
        const status = page.locator('#status');
        await expect(status).toHaveText('Cleared');
    });

    test('keyboard shortcut Ctrl+Enter runs code', async ({ page }) => {
        const isReady = await waitForInit(page);
        test.skip(!isReady, 'WebGPU not available');

        // Focus textarea
        const textarea = page.locator('#source');
        await textarea.focus();

        // Press Ctrl+Enter
        await page.keyboard.press('Control+Enter');

        // Wait for execution
        await page.waitForFunction(() => {
            const status = document.getElementById('status');
            return status && (status.textContent.includes('Done') || status.textContent.includes('Error'));
        }, { timeout: 5000 });

        // Should have run (either success or error, but not still "Ready")
        const status = page.locator('#status');
        await expect(status).not.toHaveText('Ready');
    });

});

test.describe('PNGine WebGPU - Edge Cases', () => {

    test('handles empty source', async ({ page }) => {
        await page.goto('/');
        const isReady = await waitForInit(page);
        test.skip(!isReady, 'WebGPU not available');

        // Clear source and run
        const textarea = page.locator('#source');
        await textarea.fill('');
        await page.click('#run-btn');

        // Should error (empty source is invalid)
        const status = page.locator('#status');
        await expect(status).toContainText('Error');
    });

    test('handles very long shader code', async ({ page }) => {
        await page.goto('/');
        const isReady = await waitForInit(page);
        test.skip(!isReady, 'WebGPU not available');

        // Create source with long shader
        const longShader = `
; Long shader test
(shader 0 "
@vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    // ${'// padding comment\\n'.repeat(100)}
    var pos = array<vec2f, 3>(
        vec2f( 0.0,  0.5),
        vec2f(-0.5, -0.5),
        vec2f( 0.5, -0.5)
    );
    return vec4f(pos[i], 0.0, 1.0);
}

@fragment fn fragmentMain() -> @location(0) vec4f {
    return vec4f(0.2, 0.8, 0.4, 1.0);
}
")

(pipeline 0 (json "{\\"vertex\\":{\\"shader\\":0,\\"entryPoint\\":\\"vertexMain\\"},\\"fragment\\":{\\"shader\\":0,\\"entryPoint\\":\\"fragmentMain\\"}}"))

(frame "main"
    (begin-render-pass :texture 0 :load clear :store store)
    (set-pipeline 0)
    (draw 3 1)
    (end-pass)
    (submit)
)
`;

        const textarea = page.locator('#source');
        await textarea.fill(longShader);
        await page.click('#run-btn');

        // Should still work
        await page.waitForFunction(() => {
            const status = document.getElementById('status');
            return status && status.textContent.includes('Done');
        }, { timeout: 10000 });

        const status = page.locator('#status');
        await expect(status).toContainText('Done');
    });

});
