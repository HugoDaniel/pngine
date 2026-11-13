//! Play page: generate the static, fully offline HTML player.
//!
//! ## Design
//! `renderPage` assembles one HTML document whose data sections hold the
//! committed runtime, the PNG, and (for executor-less input) the generic WASM
//! executor as base64. Everything is embedded — the page makes no network
//! request — and base64 means no payload byte can terminate a `<script>`.
//!
//! The HTML/CSS shell is a Zig multiline template, following
//! `js_codegen.wrapHtml`; the duration, the data blobs, and the bootstrap are
//! appended. The behavioral bootstrap is part of the same module script as the
//! two configuration constants (separate module scripts do not share scope): it
//! imports the runtime Blob, initializes the real or fallback executor, and
//! drives the time-only transport and the error overlay.
//!
//! ## Invariants
//! - Empty PNG bytes are refused with `EmptyPayload`.
//! - A duration that is not positive and finite is refused with
//!   `InvalidDuration` (zero, negative, NaN, infinity).
//! - The caller owns the returned UTF-8 HTML.

const std = @import("std");
const Allocator = std.mem.Allocator;
const js_emit = @import("js_emit.zig");

/// Everything the page generator needs. The command fills this in after
/// validating the input; `renderPage` only refuses what would produce a broken
/// page (no payload, no usable duration).
pub const Page = struct {
    /// The PNG to play, byte-for-byte as read or packaged.
    png_bytes: []const u8,
    /// The payload rides a `pNGx` envelope, so the page extracts the logical
    /// PNGB before handing bytes to the runtime.
    extract_pngx: bool = false,
    /// Generic all-plugin executor, embedded only when the PNG itself lacks
    /// one.
    fallback_executor_wasm: ?[]const u8 = null,
    /// Playback span in seconds; the transport is TIME-only and loops.
    duration_seconds: f32 = 10.0,
};

/// The committed runtime: the byte-exact production `dev.mjs` build, drift-
/// gated by `zig build drift`.
const embedded_runtime: []const u8 = @embedFile("play_runtime.min.mjs");

/// The static page shell up to the point where the duration becomes the
/// timeline's `max`; the controls, data sections, configuration constants, and
/// bootstrap are appended by `renderPage`.
const page_head =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>PNGine player</title>
    \\<style>
    \\*{box-sizing:border-box}
    \\html,body{margin:0;height:100%}
    \\body{background:#000;color:#eee;font:14px/1.4 system-ui,sans-serif;display:flex;flex-direction:column;align-items:center;gap:8px;padding:8px}
    \\#canvas{display:block;width:100%;max-width:960px;height:auto;background:#111;border-radius:4px}
    \\#controls{display:flex;flex-wrap:wrap;align-items:center;gap:8px;width:100%;max-width:960px}
    \\#play-toggle{min-width:72px;padding:6px 10px;font:inherit;cursor:pointer}
    \\#timeline{flex:1 1 160px;min-width:0;accent-color:#4af}
    \\#time-display{min-width:8ch;font-variant-numeric:tabular-nums;text-align:right;white-space:nowrap}
    \\#error-overlay{position:fixed;left:8px;right:8px;bottom:8px;max-height:50vh;overflow:auto;padding:12px;border:1px solid #f66;border-radius:6px;background:#300;color:#fff;white-space:pre-wrap}
    \\[hidden]{display:none!important}
    \\</style>
    \\</head>
    \\<body>
    \\<canvas id="canvas"></canvas>
    \\<div id="controls">
    \\<button id="play-toggle" type="button" disabled>Play</button>
    \\<input id="timeline" type="range" min="0" max="
;

/// The controls and the hidden, pre-populated overlay. Both controls start
/// disabled: the page is paused at zero until the runtime reports a successful
/// initialization. The data sections the bootstrap reads are emitted by
/// `renderPage`.
const page_controls =
    \\" step="any" value="0" aria-label="Playback position" disabled>
    \\<span id="time-display">0 / 0 s</span>
    \\</div>
    \\<div id="error-overlay" role="alert" aria-live="assertive" hidden></div>
;

/// The behavioral bootstrap. It shares one module script with `DURATION` and
/// `EXTRACT_PNGX` (module scope is not shared between script elements).
///
/// Lifetimes: the runtime Blob URL is revoked immediately after the dynamic
/// import. The fallback WASM Blob URL (http(s) only) is revoked on `pagehide`,
/// after the worker has fetched it. Under `file://` the executor travels as an
/// `application/wasm` data URL instead: Chromium gives the document an opaque
/// origin, and a blob worker cannot fetch a blob URL that origin created.
/// No test hook is exposed.
const page_bootstrap =
    \\;
    \\
    \\const runtimeSection = document.getElementById("pngine-runtime");
    \\const payloadSection = document.getElementById("pngine-payload");
    \\const executorSection = document.getElementById("pngine-executor");
    \\const canvas = document.getElementById("canvas");
    \\const playToggle = document.getElementById("play-toggle");
    \\const timeline = document.getElementById("timeline");
    \\const timeDisplay = document.getElementById("time-display");
    \\const errorOverlay = document.getElementById("error-overlay");
    \\
    \\function decodeSection(section) {
    \\    const text = section.textContent.trim();
    \\    const binary = atob(text);
    \\    const bytes = new Uint8Array(binary.length);
    \\    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    \\    return bytes;
    \\}
    \\
    \\const runtimeBytes = decodeSection(runtimeSection);
    \\const payloadBytes = decodeSection(payloadSection);
    \\const executorBytes = executorSection ? decodeSection(executorSection) : null;
    \\
    \\const runtimeUrl = URL.createObjectURL(new Blob([runtimeBytes], { type: "text/javascript" }));
    \\let runtime;
    \\try {
    \\    runtime = await import(runtimeUrl);
    \\} finally {
    \\    URL.revokeObjectURL(runtimeUrl);
    \\}
    \\
    \\let fallbackUrl = null;
    \\let wasmUrl = window.location.href;
    \\if (executorBytes) {
    \\    if (window.location.protocol === "file:") {
    \\        // Chromium gives a file:// document an opaque origin, and a blob
    \\        // worker cannot fetch a blob URL created by it ("Failed to fetch").
    \\        // A data URL is origin-free, so the worker can fetch and stream it.
    \\        wasmUrl = "data:application/wasm;base64," + executorSection.textContent.trim();
    \\    } else {
    \\        fallbackUrl = URL.createObjectURL(new Blob([executorBytes], { type: "application/wasm" }));
    \\        wasmUrl = fallbackUrl;
    \\    }
    \\}
    \\
    \\let instance = null;
    \\let playing = false;
    \\let failed = false;
    \\let uiFrame = 0;
    \\
    \\function setControlsEnabled(enabled) {
    \\    playToggle.disabled = !enabled;
    \\    timeline.disabled = !enabled;
    \\}
    \\
    \\function wrappedTime(time) {
    \\    const value = time % DURATION;
    \\    return value >= 0 ? value : value + DURATION;
    \\}
    \\
    \\function renderTime(time) {
    \\    const wrapped = wrappedTime(time);
    \\    timeline.value = String(wrapped);
    \\    timeDisplay.textContent = wrapped.toFixed(3) + " / " + DURATION.toFixed(3) + " s";
    \\}
    \\
    \\function stopUi() {
    \\    if (uiFrame) cancelAnimationFrame(uiFrame);
    \\    uiFrame = 0;
    \\}
    \\
    \\function uiTick() {
    \\    if (!instance || failed) return;
    \\    renderTime(instance.time);
    \\    uiFrame = requestAnimationFrame(uiTick);
    \\}
    \\
    \\function showError(error) {
    \\    failed = true;
    \\    playing = false;
    \\    if (instance) {
    \\        try {
    \\            runtime.pause(instance);
    \\        } catch {}
    \\    }
    \\    stopUi();
    \\    setControlsEnabled(false);
    \\    playToggle.textContent = "Play";
    \\    const name = error && error.name ? error.name : "Error";
    \\    const message = error && error.message ? error.message : String(error);
    \\    const source = error && error.source ? " (source: " + error.source + ")" : "";
    \\    errorOverlay.textContent = "PNGine playback error: " + name + ": " + message + source;
    \\    errorOverlay.hidden = false;
    \\}
    \\
    \\async function inflateRaw(bytes) {
    \\    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    \\    return new Uint8Array(await new Response(stream).arrayBuffer());
    \\}
    \\
    \\async function logicalPayload() {
    \\    if (!EXTRACT_PNGX) return payloadBytes;
    \\    const payloads = [];
    \\    for (const entry of runtime.payloadsOf(payloadBytes)) {
    \\        if (!entry.skip && entry.kind === "PNGB") payloads.push(entry);
    \\    }
    \\    if (payloads.length !== 1) {
    \\        throw new Error("expected exactly one PNGB payload, found " + payloads.length);
    \\    }
    \\    const entry = payloads[0];
    \\    return (entry.flags & 1) ? await inflateRaw(entry.body) : entry.body;
    \\}
    \\
    \\playToggle.addEventListener("click", () => {
    \\    if (!instance || failed) return;
    \\    if (playing) {
    \\        runtime.pause(instance);
    \\        playing = false;
    \\        playToggle.textContent = "Play";
    \\    } else {
    \\        runtime.play(instance);
    \\        playing = true;
    \\        playToggle.textContent = "Pause";
    \\    }
    \\});
    \\
    \\timeline.addEventListener("input", () => {
    \\    if (!instance || failed) return;
    \\    const requested = Number(timeline.value);
    \\    const time = Math.min(Math.max(Number.isFinite(requested) ? requested : 0, 0), DURATION);
    \\    runtime.seek(instance, time);
    \\    renderTime(time);
    \\});
    \\
    \\addEventListener("pagehide", () => {
    \\    stopUi();
    \\    if (instance) {
    \\        try {
    \\            runtime.destroy(instance);
    \\        } catch {}
    \\        instance = null;
    \\    }
    \\    if (fallbackUrl) {
    \\        URL.revokeObjectURL(fallbackUrl);
    \\        fallbackUrl = null;
    \\    }
    \\});
    \\
    \\async function start() {
    \\    try {
    \\        const payload = await logicalPayload();
    \\        const created = await runtime.pngine(payload, {
    \\            canvas: canvas,
    \\            autoResize: true,
    \\            wasmUrl: wasmUrl,
    \\            onError: showError,
    \\        });
    \\        if (failed) {
    \\            try {
    \\                runtime.destroy(created);
    \\            } catch {}
    \\            return;
    \\        }
    \\        instance = created;
    \\        setControlsEnabled(true);
    \\        uiFrame = requestAnimationFrame(uiTick);
    \\    } catch (error) {
    \\        showError(error);
    \\    }
    \\}
    \\
    \\start();
    \\</script>
    \\</body>
    \\</html>
;

/// Write one base64 data section. Base64 has no `<`, so no payload byte can
/// close the script element early.
fn emitData(out: *std.ArrayList(u8), gpa: Allocator, id: []const u8, data: []const u8) !void {
    try out.appendSlice(gpa, "<script type=\"text/plain\" id=\"");
    try out.appendSlice(gpa, id);
    try out.appendSlice(gpa, "\">");
    try js_emit.base64Append(out, gpa, data);
    try out.appendSlice(gpa, "</script>\n");
}

/// Render the complete offline player page. Caller owns the returned UTF-8.
pub fn renderPage(gpa: Allocator, page: Page) ![]u8 {
    if (page.png_bytes.len == 0) return error.EmptyPayload;
    if (!std.math.isFinite(page.duration_seconds) or page.duration_seconds <= 0) {
        return error.InvalidDuration;
    }

    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(gpa);

    try html.appendSlice(gpa, page_head);
    try js_emit.appendCompactFloat(&html, gpa, page.duration_seconds);
    try html.appendSlice(gpa, page_controls);

    try emitData(&html, gpa, "pngine-runtime", embedded_runtime);
    try emitData(&html, gpa, "pngine-payload", page.png_bytes);
    if (page.fallback_executor_wasm) |wasm| {
        try emitData(&html, gpa, "pngine-executor", wasm);
    }

    try html.appendSlice(gpa, "<script type=\"module\">\nconst DURATION = ");
    try js_emit.appendCompactFloat(&html, gpa, page.duration_seconds);
    try html.appendSlice(gpa, ";\nconst EXTRACT_PNGX = ");
    try html.appendSlice(gpa, if (page.extract_pngx) "true" else "false");
    try html.appendSlice(gpa, page_bootstrap);

    return html.toOwnedSlice(gpa);
}

// ============================================================================
// Tests
// ============================================================================

/// The text content of the `<script type="text/plain" id="...">` data section.
fn sectionBody(html: []const u8, id: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "id=\"{s}\">", .{id}) catch return null;
    const opened = std.mem.indexOf(u8, html, needle) orelse return null;
    const body_start = opened + needle.len;
    const body_end = std.mem.indexOfPos(u8, html, body_start, "</script>") orelse return null;
    return html[body_start..body_end];
}

/// Decode one of the page's standard-base64 data sections.
fn decodeBase64(gpa: Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(text);
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    try decoder.decode(out, text);
    return out;
}
