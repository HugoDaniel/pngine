import { describe, test, expect } from "vitest"
import { isPngineSource } from "../src/index.ts"

// `isPngineSource` is the single predicate behind both compile call sites
// (`resolveId` for `?png` imports and `handleHotUpdate` for HMR). It decides
// which source files route through the pngine CLI compile path. Phase 3 made
// the CLI accept `.sjon` as a first-class input alongside `.pngine`, so both
// extensions must resolve here; `.pbsf` (legacy S-expressions) is not a
// build/browser concern and stays out.
describe("isPngineSource", () => {
	test("accepts .pngine source", () => {
		expect(isPngineSource("shader.pngine")).toBe(true)
		expect(isPngineSource("/abs/path/to/shader.pngine")).toBe(true)
	})

	test("accepts .sjon source (Phase 4: CLI takes it as a first-class input)", () => {
		expect(isPngineSource("shader.sjon")).toBe(true)
		expect(isPngineSource("/abs/path/to/shader.sjon")).toBe(true)
	})

	test("rejects compiled .png (not a source)", () => {
		expect(isPngineSource("shader.png")).toBe(false)
	})

	test("rejects .pbsf legacy source (not a build/browser concern)", () => {
		expect(isPngineSource("shader.pbsf")).toBe(false)
	})

	test("rejects unrelated extensions", () => {
		expect(isPngineSource("main.js")).toBe(false)
		expect(isPngineSource("style.css")).toBe(false)
		expect(isPngineSource("index.html")).toBe(false)
	})

	test("matches only the trailing extension, not a substring", () => {
		// `.pngine`/`.sjon` in the middle of a name must not match.
		expect(isPngineSource("shader.pngine.txt")).toBe(false)
		expect(isPngineSource("notes.sjon.bak")).toBe(false)
		expect(isPngineSource("sjon-shader.png")).toBe(false)
	})
})
