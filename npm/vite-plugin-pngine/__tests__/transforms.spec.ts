import { describe, test, expect } from "vitest"
import { replaceScript, replaceCss } from "../src/index.ts"

describe("replaceScript", () => {
	test("inlines script and preserves other attributes", () => {
		expect(
			replaceScript(`<script module src="./foo.js"></script>`, "foo.js", "console.log('hi')")
		).toEqual(`<script module>console.log('hi')</script>`)
	})

	test("handles relative path with ./", () => {
		expect(
			replaceScript(`<script type="module" src="./main.js"></script>`, "main.js", "code()")
		).toEqual(`<script type="module">code()</script>`)
	})

	test("handles absolute path", () => {
		expect(
			replaceScript(`<script type="module" src="/assets/main.js"></script>`, "assets/main.js", "code()")
		).toEqual(`<script type="module">code()</script>`)
	})

	test("handles full URL with domain", () => {
		expect(
			replaceScript(`<script module src="https://cdn.example.com/path/foo.js"></script>`, "foo.js", "code()")
		).toEqual(`<script module>code()</script>`)
	})

	test("preserves multiple attributes in correct order", () => {
		expect(
			replaceScript(`<script async type="module" crossorigin src="/assets/app.js"></script>`, "assets/app.js", "code()")
		).toEqual(`<script async type="module" crossorigin>code()</script>`)

		expect(
			replaceScript(`<script src="./app.js" async type="module"></script>`, "app.js", "code()")
		).toEqual(`<script async type="module">code()</script>`)
	})

	test("escapes </script> in inlined code", () => {
		const code = `document.write("</script>")`
		const result = replaceScript(`<script src="./foo.js"></script>`, "foo.js", code)
		expect(result).toContain("\\x3C/script>")
		expect(result).not.toContain("</script></script>")
	})

	test("escapes <!-- in inlined code", () => {
		const code = `const x = "<!-- comment -->"`
		const result = replaceScript(`<script src="./foo.js"></script>`, "foo.js", code)
		expect(result).toContain("\\x3C!--")
	})

	test("replaces __VITE_PRELOAD__ with void 0", () => {
		const code = `const deps = __VITE_PRELOAD__`
		const result = replaceScript(`<script src="./foo.js"></script>`, "foo.js", code)
		expect(result).toContain("void 0")
		expect(result).not.toContain("__VITE_PRELOAD__")
	})

	test("replaces quoted __VITE_PRELOAD__", () => {
		const code = `const deps = "__VITE_PRELOAD__"`
		const result = replaceScript(`<script src="./foo.js"></script>`, "foo.js", code)
		expect(result).toContain("void 0")
	})

	test("removes Vite module loader polyfill when requested", () => {
		const html = `<script type="module" crossorigin>(function polyfill() {stuff here\nfoo})();const app = true;</script>`
		const result = replaceScript(html, "", "", true)
		expect(result).toContain(`<script type="module">const app = true;`)
		expect(result).not.toContain("polyfill")
	})

	test("removes minified Vite module loader when requested", () => {
		const html = `<script type="module" crossorigin>(function(){stuff here\nfoo})();const app = true;</script>`
		const result = replaceScript(html, "", "", true)
		expect(result).toContain(`<script type="module">const app = true;`)
		expect(result).not.toContain("(function()")
	})

	test("returns html unchanged when script tag not found", () => {
		const html = `<script src="./other.js"></script>`
		expect(replaceScript(html, "foo.js", "code()")).toEqual(html)
	})

	test("trims whitespace from inlined code", () => {
		const result = replaceScript(`<script src="./foo.js"></script>`, "foo.js", "  code()  \n")
		expect(result).toEqual(`<script>code()</script>`)
	})
})

describe("replaceCss", () => {
	test("converts link to inline style", () => {
		expect(
			replaceCss(`<link rel="stylesheet" href="./style.css">`, "style.css", "body { color: red; }")
		).toEqual(`<style>body { color: red; }</style>`)
	})

	test("handles absolute path", () => {
		expect(
			replaceCss(`<link rel="stylesheet" href="/assets/style.css">`, "assets/style.css", "body{}")
		).toEqual(`<style>body{}</style>`)
	})

	test("handles full URL", () => {
		expect(
			replaceCss(`<link rel="stylesheet" href="https://cdn.example.com/style.css">`, "style.css", "body{}")
		).toEqual(`<style>body{}</style>`)
	})

	test("removes @charset declaration", () => {
		const css = `@charset "UTF-8";\nbody { color: red; }`
		const result = replaceCss(`<link href="./style.css">`, "style.css", css)
		expect(result).not.toContain("@charset")
		expect(result).toContain("body { color: red; }")
	})

	test("drops link attributes (rel, crossorigin are invalid on style)", () => {
		expect(
			replaceCss(`<link rel="stylesheet" crossorigin href="./style.css">`, "style.css", "body{}")
		).toEqual(`<style>body{}</style>`)
	})

	test("returns html unchanged when link tag not found", () => {
		const html = `<link href="./other.css">`
		expect(replaceCss(html, "style.css", "body{}")).toEqual(html)
	})
})
