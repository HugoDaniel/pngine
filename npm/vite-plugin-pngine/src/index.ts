import type { UserConfig, PluginOption, ViteDevServer, Connect } from "vite"
import type { OutputChunk, OutputAsset, OutputOptions } from "rollup"
import { execFileSync } from "node:child_process"
import { readFileSync, statSync } from "node:fs"
import { resolve, dirname, join } from "node:path"
import { tmpdir } from "node:os"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PnginePluginOptions {
	/** Enable single-file HTML output in production builds. @default true */
	singleFile?: boolean
	/** Remove the Vite module loader polyfill from output. @default true */
	removeViteModuleLoader?: boolean
	/** Delete inlined files from the output directory. @default true */
	deleteInlinedFiles?: boolean
	/** Compile .pngine / .sjon source files to PNG via CLI. @default false */
	compile?: boolean
	/** Options passed to the pngine CLI when compile is enabled. */
	compileOptions?: {
		/** Embed executor WASM in PNG. @default true */
		embed?: boolean
		/** Minify WGSL shaders. @default true in production, false in dev */
		minify?: boolean
	}
}

const defaults: Required<PnginePluginOptions> = {
	singleFile: true,
	removeViteModuleLoader: true,
	deleteInlinedFiles: true,
	compile: false,
	compileOptions: { embed: true, minify: true },
}

// ---------------------------------------------------------------------------
// HTML transform functions (exported for unit testing)
// ---------------------------------------------------------------------------

const isJsFile = /\.[mc]?js$/
const isCssFile = /\.css$/
const isHtmlFile = /\.html?$/

/**
 * Inline a JS file into a `<script>` tag in HTML.
 * Ported from vite-plugin-singlefile.
 */
export function replaceScript(
	html: string,
	scriptFilename: string,
	scriptCode: string,
	removeModuleLoader = false,
): string {
	const f = scriptFilename.replaceAll(".", "\\.")
	const reScript = new RegExp(`<script([^>]*?) src="(?:[^"]*?/)?${f}"([^>]*)></script>`)
	const preloadMarker = /"?__VITE_PRELOAD__"?/g
	const newCode = scriptCode.replace(preloadMarker, "void 0").replace(/<(\/script>|!--)/g, "\\x3C$1")
	const inlined = html.replace(reScript, (_, beforeSrc, afterSrc) => `<script${beforeSrc}${afterSrc}>${newCode.trim()}</script>`)
	return removeModuleLoader ? _removeViteModuleLoader(inlined) : inlined
}

/**
 * Convert a `<link>` stylesheet into an inline `<style>` tag.
 * Ported from vite-plugin-singlefile.
 */
export function replaceCss(html: string, cssFilename: string, cssCode: string): string {
	const f = cssFilename.replaceAll(".", "\\.")
	const reStyle = new RegExp(`<link([^>]*?) href="(?:[^"]*?/)?${f}"([^>]*)>`)
	const newCode = cssCode.replace(`@charset "UTF-8";`, "")
	return html.replace(reStyle, () => `<style>${newCode.trim()}</style>`)
}

/**
 * Strip Vite's module loader polyfill IIFE.
 */
function _removeViteModuleLoader(html: string): string {
	return html.replace(
		/(<script type="module" crossorigin>\s*)\(function(?: polyfill)?\(\)\s*\{[\s\S]*?\}\)\(\);/,
		'<script type="module">',
	)
}

// ---------------------------------------------------------------------------
// .pngine / .sjon compilation helper
// ---------------------------------------------------------------------------

/**
 * Source extensions the pngine CLI compiles to a PNG. Both `.pngine` (macro
 * DSL) and `.sjon` (SJON dialect) are first-class CLI inputs that route through
 * the identical compile path, so the `?png` import resolver and the HMR handler
 * treat them the same. Single source of truth: keep both call sites
 * (`resolveId`, `handleHotUpdate`) on this helper so they cannot drift.
 */
export function isPngineSource(filePath: string): boolean {
	return filePath.endsWith(".pngine") || filePath.endsWith(".sjon")
}

const compileCache = new Map<string, { mtime: number; data: Buffer }>()

function compilePngine(filePath: string, opts: PnginePluginOptions["compileOptions"]): Buffer {
	const absPath = resolve(filePath)
	const mtime = statSync(absPath).mtimeMs

	const cached = compileCache.get(absPath)
	if (cached && cached.mtime === mtime) {
		return cached.data
	}

	const tmpOut = join(tmpdir(), `pngine-${Date.now()}-${Math.random().toString(36).slice(2)}.png`)
	const args = [absPath, "-o", tmpOut]
	if (opts?.embed !== false) args.push("--embed")
	if (opts?.minify !== false) args.push("--minify")

	const bin = findPngineBin()
	execFileSync(bin, args, { stdio: "pipe" })

	const data = readFileSync(tmpOut)
	compileCache.set(absPath, { mtime, data })
	return data
}

function findPngineBin(): string {
	// Try local node_modules first
	try {
		const pkgPath = require.resolve("pngine/package.json")
		const binPath = join(dirname(pkgPath), "bin", "pngine")
		statSync(binPath)
		return binPath
	} catch {
		// Fall back to npx
		return "npx"
	}
}

// ---------------------------------------------------------------------------
// Dev mode alias resolution
// ---------------------------------------------------------------------------

const PNGINE_INTERNAL_MODULES = [
	"worker.js",
	"worker-viewer.js",
	"gpu.js",
	"gpu-resource-pass-commands.js",
	"anim.js",
	"extract.js",
	"audio.js",
	"init.js",
	"loader.js",
	"viewer-init.js",
	"viewer.js",
	"compiler.js",
	"enums.js",
]

function getPngineAliases(): Record<string, string> {
	let srcDir: string
	try {
		const pkgPath = require.resolve("pngine/package.json")
		srcDir = join(dirname(pkgPath), "src")
		// Check if src/ exists (development install), fall back to dist/
		statSync(srcDir)
	} catch {
		try {
			const pkgPath = require.resolve("pngine/package.json")
			srcDir = join(dirname(pkgPath), "dist")
		} catch {
			return {}
		}
	}

	const aliases: Record<string, string> = {
		pngine: join(srcDir, "index.js"),
	}

	for (const mod of PNGINE_INTERNAL_MODULES) {
		aliases[`./${mod}`] = join(srcDir, mod)
	}

	return aliases
}

// ---------------------------------------------------------------------------
// Plugin factory
// ---------------------------------------------------------------------------

const VIRTUAL_COMPILE_PREFIX = "\0pngine-compile:"
const PNGINE_QUERY = "?png"

export function pnginePlugin(userOpts: PnginePluginOptions = {}): PluginOption[] {
	const opts = { ...defaults, ...userOpts }
	opts.compileOptions = { ...defaults.compileOptions, ...userOpts.compileOptions }

	let isDev = false

	// -----------------------------------------------------------------------
	// Plugin 1: Configuration (enforce: "pre")
	// -----------------------------------------------------------------------
	const configPlugin: PluginOption = {
		name: "vite-plugin-pngine:config",
		enforce: "pre",

		config(config: UserConfig, { mode }: { mode: string }) {
			isDev = mode === "development"

			if (!config.define) config.define = {}
			config.define["DEBUG"] = JSON.stringify(isDev)

			if (!config.assetsInclude) config.assetsInclude = []
			if (Array.isArray(config.assetsInclude)) {
				config.assetsInclude.push("**/*.wasm")
			}

			if (opts.singleFile && !isDev) {
				if (!config.build) config.build = {}
				config.build.assetsInlineLimit = () => true
				config.build.chunkSizeWarningLimit = 100_000_000
				config.build.cssCodeSplit = false
				config.build.assetsDir = ""
				config.base = "./"

				if (!config.build.rollupOptions) config.build.rollupOptions = {}
				if (!config.build.rollupOptions.output) config.build.rollupOptions.output = {}

				const setOutputOpts = (out: OutputOptions) => {
					out.inlineDynamicImports = true
				}

				if (Array.isArray(config.build.rollupOptions.output)) {
					for (const o of config.build.rollupOptions.output) setOutputOpts(o as OutputOptions)
				} else {
					setOutputOpts(config.build.rollupOptions.output as OutputOptions)
				}
			}

			// Dev mode: resolve PNGine internal modules via aliases
			if (isDev) {
				const aliases = getPngineAliases()
				if (Object.keys(aliases).length > 0) {
					if (!config.resolve) config.resolve = {}
					if (!config.resolve.alias) config.resolve.alias = {}

					if (typeof config.resolve.alias === "object" && !Array.isArray(config.resolve.alias)) {
						Object.assign(config.resolve.alias, aliases)
					}
				}
			}
		},

		configureServer(server: ViteDevServer) {
			// Serve .wasm files with correct MIME type
			server.middlewares.use((req: Connect.IncomingMessage, _res, next) => {
				if (req.url?.endsWith(".wasm")) {
					_res.setHeader("Content-Type", "application/wasm")
				}
				next()
			})
		},
	}

	// -----------------------------------------------------------------------
	// Plugin 2: Build transforms (enforce: "post")
	// -----------------------------------------------------------------------
	const buildPlugin: PluginOption = {
		name: "vite-plugin-pngine:build",
		enforce: "post",

		resolveId(source: string) {
			if (!opts.compile) return null

			if (source.endsWith(PNGINE_QUERY)) {
				const filePath = source.slice(0, -PNGINE_QUERY.length)
				if (isPngineSource(filePath)) {
					return VIRTUAL_COMPILE_PREFIX + resolve(filePath)
				}
			}
			return null
		},

		load(id: string) {
			if (!id.startsWith(VIRTUAL_COMPILE_PREFIX)) return null

			const filePath = id.slice(VIRTUAL_COMPILE_PREFIX.length)
			try {
				const pngData = compilePngine(filePath, {
					...opts.compileOptions,
					minify: isDev ? false : (opts.compileOptions?.minify ?? true),
				})
				const base64 = pngData.toString("base64")
				return `export default "data:image/png;base64,${base64}"`
			} catch (err: unknown) {
				const msg = err instanceof Error ? err.message : String(err)
				this.error(`Failed to compile ${filePath}: ${msg}`)
			}
		},

		handleHotUpdate({ file, server }: { file: string; server: ViteDevServer }) {
			if (!opts.compile) return
			if (!isPngineSource(file)) return

			// Invalidate compile cache
			compileCache.delete(file)

			// Invalidate modules that imported this .pngine file
			const mod = server.moduleGraph.getModuleById(VIRTUAL_COMPILE_PREFIX + file)
			if (mod) {
				server.moduleGraph.invalidateModule(mod)
				return [...(mod.importers || [])]
			}
		},

		generateBundle(_options: unknown, bundle: Record<string, OutputChunk | OutputAsset>) {
			if (!opts.singleFile || isDev) return

			this.info("\n")

			const files = {
				html: [] as string[],
				css: [] as string[],
				js: [] as string[],
				other: [] as string[],
			}

			for (const name of Object.keys(bundle)) {
				if (isHtmlFile.test(name)) {
					files.html.push(name)
				} else if (isCssFile.test(name)) {
					files.css.push(name)
				} else if (isJsFile.test(name)) {
					files.js.push(name)
				} else {
					files.other.push(name)
				}
			}

			const bundlesToDelete: string[] = []

			for (const htmlName of files.html) {
				const htmlChunk = bundle[htmlName] as OutputAsset
				let html = htmlChunk.source as string

				for (const jsName of files.js) {
					const jsChunk = bundle[jsName] as OutputChunk
					if (jsChunk.code != null) {
						this.info(`Inlining: ${jsName}`)
						bundlesToDelete.push(jsName)
						html = replaceScript(html, jsChunk.fileName, jsChunk.code, opts.removeViteModuleLoader)
					}
				}

				for (const cssName of files.css) {
					const cssChunk = bundle[cssName] as OutputAsset
					this.info(`Inlining: ${cssName}`)
					bundlesToDelete.push(cssName)
					html = replaceCss(html, cssChunk.fileName, cssChunk.source as string)
				}

				htmlChunk.source = html
			}

			if (opts.deleteInlinedFiles) {
				for (const name of bundlesToDelete) {
					delete bundle[name]
				}
			}

			for (const name of files.other) {
				this.info(`NOTE: asset not inlined: ${name}`)
			}
		},
	}

	return [configPlugin, buildPlugin]
}
