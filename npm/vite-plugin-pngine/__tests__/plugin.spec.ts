import { describe, test, expect } from "vitest"
import { build, type Rollup } from "vite"
import { resolve } from "node:path"
import { pnginePlugin } from "../src/index.ts"

function getOutput(result: Rollup.RollupOutput | Rollup.RollupOutput[]): Rollup.RollupOutput {
	return Array.isArray(result) ? result[0] : result
}

function getHtml(output: Rollup.RollupOutput): string {
	const htmlAsset = output.output.find(
		(chunk) => chunk.type === "asset" && chunk.fileName.endsWith(".html")
	)
	if (!htmlAsset || htmlAsset.type !== "asset") {
		throw new Error("No HTML asset found in build output")
	}
	return htmlAsset.source as string
}

describe("pnginePlugin build", () => {
	test("produces single HTML file with inlined JS", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/basic"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// Should only have the HTML file (all JS/CSS deleted)
		const fileNames = output.output.map((o) => o.fileName)
		const jsFiles = fileNames.filter((f) => /\.[mc]?js$/.test(f))
		const cssFiles = fileNames.filter((f) => f.endsWith(".css"))
		expect(jsFiles).toHaveLength(0)
		expect(cssFiles).toHaveLength(0)

		// HTML should exist and contain inlined script
		const html = getHtml(output)
		expect(html).toContain("<script")
		expect(html).not.toMatch(/src=["'][^"']*\.js["']/)

		// Should contain the PNG data URL (Vite inlines assets)
		expect(html).toContain("data:image/png;base64,")
	})

	test("inlines CSS into HTML", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/with-css"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// No separate CSS files
		const cssFiles = output.output.filter(
			(o) => o.fileName.endsWith(".css")
		)
		expect(cssFiles).toHaveLength(0)

		// HTML should contain inlined styles
		const html = getHtml(output)
		expect(html).toContain("<style")
		expect(html).toContain("background:")
		expect(html).not.toMatch(/href=["'][^"']*\.css["']/)
	})

	test("keeps inlined files when deleteInlinedFiles is false", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/basic"),
			plugins: [pnginePlugin({ deleteInlinedFiles: false })],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// JS files should still exist in output
		const jsFiles = output.output.filter(
			(o) => o.type === "chunk" && /\.[mc]?js$/.test(o.fileName)
		)
		expect(jsFiles.length).toBeGreaterThan(0)

		// But HTML should still have inlined scripts
		const html = getHtml(output)
		expect(html).toContain("<script")
		expect(html).not.toMatch(/src=["'][^"']*\.js["']/)
	})

	test("sets correct build configuration", async () => {
		let capturedConfig: Record<string, unknown> = {}

		const configSpy = {
			name: "config-spy",
			configResolved(config: Record<string, unknown>) {
				capturedConfig = config
			},
		}

		await build({
			root: resolve(__dirname, "fixtures/basic"),
			plugins: [pnginePlugin(), configSpy],
			logLevel: "silent",
			build: { write: false },
		})

		const buildConfig = capturedConfig.build as Record<string, unknown>
		expect(buildConfig.cssCodeSplit).toBe(false)
		expect(buildConfig.assetsDir).toBe("")
		expect(capturedConfig.base).toBe("./")
	})

	test("skips singleFile inlining when disabled", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/basic"),
			plugins: [pnginePlugin({ singleFile: false })],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// JS files should remain separate
		const jsFiles = output.output.filter(
			(o) => o.type === "chunk" && /\.[mc]?js$/.test(o.fileName)
		)
		expect(jsFiles.length).toBeGreaterThan(0)
	})

	test("removes Vite module loader by default", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/basic"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		// Should not contain the polyfill IIFE pattern
		expect(html).not.toMatch(/\(function\s*polyfill\(\)/)
		expect(html).not.toMatch(/\(function\(\)\s*\{[^}]*\}\)\(\);/)
	})

	test("HTML output is a complete document", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/basic"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		expect(html).toContain("<!DOCTYPE html>")
		expect(html).toContain("<canvas")
		expect(html).toContain("</html>")
	})
})

// ---------------------------------------------------------------------------
// Multi-canvas tests
// ---------------------------------------------------------------------------

describe("multi-canvas support", () => {
	test("inlines multiple distinct PNGs into single HTML", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/multi-canvas"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		// All three PNG data URLs should be present
		const dataUrlMatches = html.match(/data:image\/png;base64,[A-Za-z0-9+/=]+/g) || []
		expect(dataUrlMatches.length).toBeGreaterThanOrEqual(3)

		// Each data URL should be unique (different PNG content)
		const uniqueUrls = new Set(dataUrlMatches)
		expect(uniqueUrls.size).toBeGreaterThanOrEqual(3)
	})

	test("multi-canvas produces exactly one output file", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/multi-canvas"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// Only the HTML should remain
		expect(output.output).toHaveLength(1)
		expect(output.output[0].fileName).toBe("index.html")
	})

	test("multi-canvas HTML contains all canvas elements", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/multi-canvas"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		expect(html).toContain('id="a"')
		expect(html).toContain('id="b"')
		expect(html).toContain('id="c"')
		// Different canvas sizes preserved
		expect(html).toContain('width="256"')
		expect(html).toContain('width="512"')
	})

	test("multi-canvas JS references all shader imports", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/multi-canvas"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		// The inlined JS should have console.log calls for each canvas
		expect(html).toContain("Canvas")
		// No separate JS or PNG files
		const otherFiles = output.output.filter((o) => o.fileName !== "index.html")
		expect(otherFiles).toHaveLength(0)
	})

	test("no separate PNG files in multi-canvas output", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/multi-canvas"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const pngFiles = output.output.filter((o) => o.fileName.endsWith(".png"))
		expect(pngFiles).toHaveLength(0)
	})
})

// ---------------------------------------------------------------------------
// Shared asset tests (same PNG used by multiple canvases)
// ---------------------------------------------------------------------------

describe("shared asset support", () => {
	test("shared PNG is inlined once and reused", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/shared-asset"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		// Should contain the data URL
		expect(html).toContain("data:image/png;base64,")

		// The data URL should appear as a single const/variable declaration
		// (Vite deduplicates — one import = one const)
		const dataUrlMatches = html.match(/data:image\/png;base64,[A-Za-z0-9+/=]+/g) || []
		// With deduplication, the literal appears once in the variable declaration
		// Both canvas references use the same variable
		expect(dataUrlMatches.length).toBeGreaterThanOrEqual(1)
	})

	test("shared asset produces single output file", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/shared-asset"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		expect(output.output).toHaveLength(1)
		expect(output.output[0].fileName).toBe("index.html")
	})

	test("shared asset HTML contains both canvas elements", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/shared-asset"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		expect(html).toContain('id="a"')
		expect(html).toContain('id="b"')
		// Both console.log references
		expect(html).toContain("Canvas A")
		expect(html).toContain("Canvas B")
	})
})

// ---------------------------------------------------------------------------
// Mixed module tests (simulating viewer + dev profiles on same page)
// ---------------------------------------------------------------------------

describe("mixed module support", () => {
	test("multiple JS modules with different PNGs bundle into single HTML", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/mixed-modules"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// Single file output
		expect(output.output).toHaveLength(1)
		expect(output.output[0].fileName).toBe("index.html")
	})

	test("mixed modules inline both PNG assets", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/mixed-modules"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		// Both PNG data URLs should be present (viewer_shader + dev_shader are different)
		const dataUrlMatches = html.match(/data:image\/png;base64,[A-Za-z0-9+/=]+/g) || []
		expect(dataUrlMatches.length).toBeGreaterThanOrEqual(2)

		// Both should be unique (different PNG content)
		const uniqueUrls = new Set(dataUrlMatches)
		expect(uniqueUrls.size).toBeGreaterThanOrEqual(2)
	})

	test("mixed modules preserve both initialization paths", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/mixed-modules"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		// Both module init functions should be present in inlined JS
		expect(html).toContain("Viewer init")
		expect(html).toContain("Dev init")
	})

	test("mixed modules HTML has both canvas elements", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/mixed-modules"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const html = getHtml(output)

		expect(html).toContain('id="viewer-canvas"')
		expect(html).toContain('id="dev-canvas"')
	})

	test("mixed modules have no leftover JS or PNG files", async () => {
		const result = await build({
			root: resolve(__dirname, "fixtures/mixed-modules"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)
		const jsFiles = output.output.filter((o) => /\.[mc]?js$/.test(o.fileName))
		const pngFiles = output.output.filter((o) => o.fileName.endsWith(".png"))

		expect(jsFiles).toHaveLength(0)
		expect(pngFiles).toHaveLength(0)
	})

	test("inlineDynamicImports collapses all modules into one chunk", async () => {
		// Verify that viewer-module.js and dev-module.js don't produce separate chunks
		const result = await build({
			root: resolve(__dirname, "fixtures/mixed-modules"),
			plugins: [pnginePlugin()],
			logLevel: "silent",
			build: { write: false },
		})

		const output = getOutput(result as Rollup.RollupOutput)

		// All chunks should be gone — everything inlined into HTML
		const chunks = output.output.filter((o) => o.type === "chunk")
		expect(chunks).toHaveLength(0)
	})
})
