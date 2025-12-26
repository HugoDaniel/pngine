// @ts-check
import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright configuration for PNGine E2E tests.
 *
 * Note: WebGPU requires Chrome with specific flags.
 * Headless Chrome currently has limited WebGPU support.
 */
export default defineConfig({
    testDir: './tests/e2e',
    fullyParallel: true,
    forbidOnly: !!process.env.CI,
    retries: process.env.CI ? 2 : 0,
    workers: process.env.CI ? 1 : undefined,
    reporter: 'html',

    use: {
        baseURL: 'http://localhost:5173',
        trace: 'on-first-retry',
        screenshot: 'only-on-failure',
    },

    projects: [
        {
            name: 'chromium',
            use: {
                ...devices['Desktop Chrome'],
                // Enable WebGPU in Chrome
                launchOptions: {
                    args: [
                        '--enable-features=Vulkan,UseSkiaRenderer',
                        '--enable-unsafe-webgpu',
                        '--use-angle=vulkan',
                    ],
                },
            },
        },
    ],

    // Start Vite dev server before tests
    webServer: {
        command: 'npm run dev',
        url: 'http://localhost:5173',
        reuseExistingServer: !process.env.CI,
        timeout: 30000,
    },
});
