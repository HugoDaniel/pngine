//! Typed value readers over the SJON forest — the SJON analog of the legacy
//! `emitter/utils.zig`.
//!
//! A `Reader` bundles an `Ast.Tree` with its `MaterializedDefaults` overlay (via
//! `EffectiveView`) so the emitter can read effective key values (author kvpair
//! first, schema default second) uniformly. The source tree pairs with
//! `HostResult.materialized_defaults`; hook-emitted lowered forms pair with an
//! empty overlay (the `pngine/*` hooks emit every key they need explicitly).
//!
//! Child forms (`(vertex …)`, `(entry …)`, `(target …)`) are read off
//! `formHeader().children`, filtering `.form` children by head. Expression /
//! define-reference values (`(* NUM 4 4)`, `(ceil (/ NUM 64))`, bare `NUM`) are
//! evaluated with `Expr.eval` against the `#define` environment.

const std = @import("std");
const sjon = @import("sjon");

const Ast = sjon.Ast;
const Expr = sjon.Expr;
const Schema = sjon.Schema;
const MaterializedDefaults = sjon.MaterializedDefaults.MaterializedDefaults;

pub const EffectiveView = sjon.EffectiveView.EffectiveView;
pub const EffectiveValue = sjon.EffectiveView.EffectiveValue;
pub const Env = sjon.Expr.Env;
pub const NodeIndex = Ast.NodeIndex;

/// Empty default overlay for lowered-form readers (hooks emit keys explicitly).
pub const empty_overlay: MaterializedDefaults = .{};

/// Read-side cursor over one tree + its default overlay.
pub const Reader = struct {
    tree: *const Ast.Tree,
    view: EffectiveView,

    pub fn init(tree: *const Ast.Tree, overlay: *const MaterializedDefaults) Reader {
        return .{ .tree = tree, .view = EffectiveView.init(tree, overlay) };
    }

    /// Wrap an already-constructed `EffectiveView`. The `pngine/*` lowering hooks
    /// hold a whole-document view while reading a container's child forms; this lets
    /// them read effective key values through the typed helpers below instead of
    /// re-implementing the author/default tag-dispatch. `view.tree` is a stable
    /// `*const Ast.Tree`, so the wrapper carries no dangling reference.
    pub fn initFromView(view: EffectiveView) Reader {
        return .{ .tree = view.tree, .view = view };
    }

    /// Head name of a form node.
    pub fn head(self: Reader, form: NodeIndex) []const u8 {
        return self.tree.formHeader(form).head;
    }

    /// All child node indices of a form (positional sub-forms + kvpairs, mixed).
    pub fn children(self: Reader, form: NodeIndex) []const NodeIndex {
        return self.tree.formHeader(form).children;
    }

    /// First positional child form whose head matches `child_head`, or null.
    pub fn child(self: Reader, form: NodeIndex, child_head: []const u8) ?NodeIndex {
        for (self.children(form)) |c| {
            if (self.tree.tagOf(c) != .form) continue;
            if (std.mem.eql(u8, self.tree.formHeader(c).head, child_head)) return c;
        }
        return null;
    }

    /// Non-allocating iterator over a form's child *forms* whose head equals
    /// `child_head`, in document order — the `.form`-tag + head filter the emitter
    /// walks for repeated positional sub-forms (`(attribute …)`, `(target …)`,
    /// `(color-attachment …)`, `(entry …)`, …). Replaces the hand-inlined
    /// `for (children) |c| { if (tagOf != .form) continue; if (!eql head) continue; }`
    /// that recurred a dozen times, so the skip logic lives in one place. Only the
    /// tree + child slice are captured, so the iterator is independent of the
    /// Reader's lifetime once constructed.
    pub const ChildFormIterator = struct {
        tree: *const Ast.Tree,
        kids: []const NodeIndex,
        child_head: []const u8,
        i: usize = 0,

        pub fn next(self: *ChildFormIterator) ?NodeIndex {
            std.debug.assert(self.i <= self.kids.len);
            std.debug.assert(self.child_head.len > 0);
            while (self.i < self.kids.len) {
                const c = self.kids[self.i];
                self.i += 1;
                if (self.tree.tagOf(c) != .form) continue;
                if (std.mem.eql(u8, self.tree.formHeader(c).head, self.child_head)) return c;
            }
            return null;
        }
    };

    /// Iterate a form's child forms with head `child_head` (see `ChildFormIterator`).
    pub fn childrenWithHead(self: Reader, form: NodeIndex, child_head: []const u8) ChildFormIterator {
        std.debug.assert(child_head.len > 0);
        return .{ .tree = self.tree, .kids = self.children(form), .child_head = child_head };
    }

    /// First positional (non-kvpair) child node of a form, or null. No pngine form
    /// carries a positional atom since overhaul/02 R1 (`(module code)`, `(topology
    /// …)` became keys); kept for `positionalSymbol` and its test below.
    pub fn firstPositional(self: Reader, form: NodeIndex) ?NodeIndex {
        for (self.children(form)) |c| {
            if (self.tree.tagOf(c) != .kvpair) return c;
        }
        return null;
    }

    /// Symbol text of the first positional of `form` (e.g. `(layout auto)` → "auto"
    /// in the test schema below). Unused by the emitter — see `firstPositional`.
    pub fn positionalSymbol(self: Reader, form: NodeIndex) ?[]const u8 {
        const p = self.firstPositional(form) orelse return null;
        return switch (self.tree.tagOf(p)) {
            .symbol => self.tree.symbolText(p),
            .keyword => self.tree.keywordText(p),
            else => null,
        };
    }

    /// Effective value node for `:key` on `form` (author kvpair only — defaults
    /// live on the overlay and are read via the typed helpers below).
    pub fn authorNode(self: Reader, form: NodeIndex, key: []const u8) ?NodeIndex {
        return self.view.getAuthorValue(form, key);
    }

    /// Read a symbol-typed key (author symbol/keyword, or defaulted keyword).
    pub fn symbol(self: Reader, form: NodeIndex, key: []const u8) ?[]const u8 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.tree.tagOf(idx)) {
                .symbol => self.tree.symbolText(idx),
                .keyword => self.tree.keywordText(idx),
                else => null,
            },
            .default => |entry| switch (entry.value) {
                .keyword => |k| k,
                else => null,
            },
        };
    }

    /// Read a string-typed key (author string).
    pub fn string(self: Reader, form: NodeIndex, key: []const u8) ?[]const u8 {
        const idx = self.authorNode(form, key) orelse return null;
        if (self.tree.tagOf(idx) != .string) return null;
        return self.tree.stringText(idx);
    }

    /// Read a literal number-typed key (author number or defaulted number).
    ///
    /// NOT FOR EMIT SITES. It reads a number node and nothing else, and since
    /// 05 §2's R7 every numeric slot in `schema/pngine.sjon` is
    /// `literal | expression | (define …) reference` — so at an emit site this
    /// returns null for two of the three shapes an author may write, and the
    /// caller's `orelse` invents a value (§368, CONTRIBUTING pitfall 82). Use
    /// `evalU32` / `evalF64`, which evaluate all three. The remaining callers
    /// are this file's own tests, over their own schemas.
    pub fn number(self: Reader, form: NodeIndex, key: []const u8) ?f64 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.tree.tagOf(idx)) {
                .number, .number_i64, .number_u64 => self.tree.numberOf(idx),
                // Backstop for the `1.0f → 0` defect: every pngine numeric kind
                // carries `:unit reject`, so a validated numeric slot never holds a
                // `number_with_unit` (this arm is unreachable there). It can still be
                // reached via the builtin-`number` alt of a union (e.g. `wasm-arg`);
                // use the magnitude, never a silent 0.
                .number_with_unit => self.tree.numberWithUnitOf(idx).value,
                else => null,
            },
            .default => |entry| switch (entry.value) {
                .number => |n| n,
                .integer_i64 => |i| @floatFromInt(i),
                .integer_u64 => |u| @floatFromInt(u),
                else => null,
            },
        };
    }

    /// Read a boolean-typed key (author `true`/`false`, or defaulted boolean).
    pub fn boolean(self: Reader, form: NodeIndex, key: []const u8) ?bool {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.tree.tagOf(idx)) {
                .boolean_true => true,
                .boolean_false => false,
                else => null,
            },
            .default => |entry| switch (entry.value) {
                .boolean => |b| b,
                else => null,
            },
        };
    }

    /// Read a member-set key whose members may be spelled digit-first (`1d`,
    /// `2d-array`, `cube`). A digit-leading spelling lexes as a unit-bearing
    /// number; SJON 1.3 accepts it in a symbol slot and matches on the parsed
    /// (magnitude, unit) pair — the tree keeps the `number_with_unit` node, it is
    /// never rewritten into a symbol. `symbol()` therefore returns null on `2d`,
    /// and an `orelse <default>` after it would silently turn `:dimension 3d`
    /// into the default (§366). This reader returns the canonical spelling for
    /// either shape: the symbol text, or `{magnitude}{unit}` rendered into `buf`
    /// (`2d`, `2.0d` and `02d` are one member to SJON, and all render as `2d`).
    /// Null only when the key is absent or holds neither shape.
    pub fn memberSpelling(self: Reader, form: NodeIndex, key: []const u8, buf: []u8) ?[]const u8 {
        std.debug.assert(buf.len >= 32);
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.tree.tagOf(idx)) {
                .symbol => self.tree.symbolText(idx),
                .keyword => self.tree.keywordText(idx),
                .number_with_unit => blk: {
                    const nu = self.tree.numberWithUnitOf(idx);
                    // SJON keys a numeric spelling by an integral, non-negative
                    // magnitude (`keyOf`); anything else could not have matched.
                    if (!(nu.value >= 0 and nu.value == @floor(nu.value))) break :blk null;
                    const magnitude: u64 = @intFromFloat(nu.value);
                    break :blk std.fmt.bufPrint(buf, "{d}{s}", .{ magnitude, nu.unit }) catch null;
                },
                else => null,
            },
            .default => |entry| switch (entry.value) {
                .keyword => |k| k,
                else => null,
            },
        };
    }

    /// Author vector elements for `:key`, or null when absent / not a vector.
    pub fn vectorNodes(self: Reader, form: NodeIndex, key: []const u8) ?[]const NodeIndex {
        const idx = self.authorNode(form, key) orelse return null;
        if (self.tree.tagOf(idx) != .vector) return null;
        return self.tree.vectorElements(idx);
    }

    /// Symbol text of a vector element node (used for name-lists).
    pub fn elemSymbol(self: Reader, elem: NodeIndex) ?[]const u8 {
        return switch (self.tree.tagOf(elem)) {
            .symbol => self.tree.symbolText(elem),
            .keyword => self.tree.keywordText(elem),
            else => null,
        };
    }

    /// f64 value of a vector element node (LITERALS only — see `elemEval`).
    ///
    /// Prefer `elemEval` at every emit site: this reader returns null for an
    /// expression or a `(define …)` reference, and null in a numeric vector
    /// means the call site's `orelse` silently invents a value.
    pub fn elemNumber(self: Reader, elem: NodeIndex) ?f64 {
        return switch (self.tree.tagOf(elem)) {
            .number, .number_i64, .number_u64 => self.tree.numberOf(elem),
            // See `number`: a unit-suffixed element uses its magnitude, never 0.
            .number_with_unit => self.tree.numberWithUnitOf(elem).value,
            else => null,
        };
    }

    /// f64 value of a vector element, EVALUATING expressions — the element-wise
    /// sibling of `evalU32`, and the reason it exists (§307): scalar slots read
    /// through `evalU32`, so `:size (* NUM 4 4)` works, while every vector
    /// element used to read through `elemNumber`, which takes number nodes and
    /// nothing else. `(dispatch :workgroups [(ceil (/ N 64)) 1 1])` therefore
    /// validated clean and emitted `dispatch(1, 1, 1)` — the call site's `orelse`
    /// standing in for a value the author wrote.
    ///
    /// Literals keep a fast path byte-identical to `elemNumber` (including the
    /// `number_with_unit` magnitude backstop), so a validated numeric vector emits
    /// exactly what it always did — the golden traces are the proof. A `form`
    /// (`(ceil …)`) or a `symbol` (a bare `(define …)` reference) evaluates against
    /// the expr env; a malformed one is an **emit error**, never a silent
    /// fallback. Anything else still returns null, so call sites keep their
    /// `orelse` for genuinely absent elements.
    pub fn elemEval(
        self: Reader,
        gpa: std.mem.Allocator,
        schema: Schema.Schema,
        env: *const Env,
        elem: NodeIndex,
    ) EvalError!?f64 {
        return switch (self.tree.tagOf(elem)) {
            .number, .number_i64, .number_u64 => self.tree.numberOf(elem),
            .number_with_unit => self.tree.numberWithUnitOf(elem).value,
            .form, .symbol => try evalNodeF64(gpa, self.tree, schema, env, elem),
            else => null,
        };
    }

    /// `elemEval` narrowed to u32 with the caller's default, for the integer
    /// vector slots (dispatch, viewport, scissor, origin, pool offsets). These
    /// are all unsigned integer wire fields, so a negative or fractional result
    /// is a `NarrowError` for the caller to locate — never clamped or truncated
    /// (audit 09 C2).
    pub fn elemU32(
        self: Reader,
        gpa: std.mem.Allocator,
        schema: Schema.Schema,
        env: *const Env,
        elem: NodeIndex,
        default: u32,
    ) EvalError!u32 {
        const n = (try self.elemEval(gpa, schema, env, elem)) orelse return default;
        return narrowF64(n);
    }

    /// Evaluate an expression-capable key (`:size (* NUM 4 4)`,
    /// `:vertex-count (ceil (/ NUM 64))`, bare define `NUM`, or a literal)
    /// to u32 against the `#define` environment. Honors the schema `:default`
    /// when the author omitted the key, so the schema — not the emitter — is the
    /// source of truth for defaulted counts/offsets. Lowered forms read through
    /// `empty_overlay` (no materialized defaults), so call sites keep an
    /// `orelse` backstop for hook-emitted forms. Returns null when the key is
    /// absent and undefaulted; errors propagate (a malformed expression is an
    /// emit error).
    pub fn evalU32(
        self: Reader,
        gpa: std.mem.Allocator,
        schema: Schema.Schema,
        env: *const Env,
        form: NodeIndex,
        key: []const u8,
    ) EvalError!?u32 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |idx| try evalNodeU32(gpa, self.tree, schema, env, idx),
            .default => |entry| switch (entry.value) {
                .number => |n| try narrowF64(n),
                .integer_i64 => |i| try narrowI64(i),
                .integer_u64 => |u| try narrowU64(u),
                else => null,
            },
        };
    }

    /// `evalU32`'s float sibling, for the slots whose wire form is a real:
    /// sampler lod clamps, depth bias terms, a depth clear value. Same three
    /// spellings (literal, expression, bare define name), same default handling,
    /// same loud failure — the difference is only that the result is not
    /// narrowed to u32.
    pub fn evalF64(
        self: Reader,
        gpa: std.mem.Allocator,
        schema: Schema.Schema,
        env: *const Env,
        form: NodeIndex,
        key: []const u8,
    ) EvalError!?f64 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.tree.tagOf(idx)) {
                .number, .number_i64, .number_u64 => self.tree.numberOf(idx),
                // See `number`: a unit-suffixed literal uses its magnitude.
                .number_with_unit => self.tree.numberWithUnitOf(idx).value,
                else => try evalNodeF64(gpa, self.tree, schema, env, idx),
            },
            .default => |entry| switch (entry.value) {
                .number => |n| n,
                .integer_i64 => |i| @as(f64, @floatFromInt(i)),
                .integer_u64 => |u| @as(f64, @floatFromInt(u)),
                else => null,
            },
        };
    }
};

/// Why an evaluated real cannot ride a u32 wire field. Four distinct tags so
/// the emitter's funnel can say WHICH rule refused — the message names the
/// value and the rule, and the squiggle lands on the expression (audit 09 C2).
pub const NarrowError = error{ Negative, NotAnInteger, AboveU32, NotFinite };

/// Error set for expression evaluation — SJON's broad `Expr.Error` (type
/// mismatches, unknown bindings, arity, …) collapses to `EmitError`; a value
/// that evaluated fine but does not fit the slot is one of the `NarrowError`
/// tags, kept distinct so the refusal can be worded.
pub const EvalError = error{ OutOfMemory, EmitError } || NarrowError;

// Narrowing an evaluated number to the u32 the wire carries.
//
// The schema's `repr` bound checks LITERALS only — it says so itself — so a
// value that arrives as an EXPRESSION (`:size (* 100000 100000)`) or as a
// define-ref reaches these three sites unchecked. Until LEAK-11 C the high
// end was a panic in the CLI and a trap-or-wrap in the ReleaseSmall wasm
// compiler; until audit 09 C2 the low end was `@max(0, n)` and a fraction was
// `@intFromFloat`'s truncation — `:size (- 5 10)` was a 0-byte buffer and
// `:vertex-count (/ 3 2)` drew one vertex, both silently, while the literal
// spellings are schema rejects (`number_below_min`, `number_not_integer`).
// The slot decides integrality and range (02 R7), so an integer slot REFUSES
// what the literal rule would refuse. Every slot that accepts an expression
// funnels through here: `:size`, draw and dispatch counts, viewport/scissor/
// origin, pool offsets, the u32 wasm args.
//
// Refusal is a `NarrowError`; the caller with a source node in hand turns it
// into a located diagnostic (`Emitter.refuseNumeric`).

/// Floating-point noise on an integer result is not a fraction: an author who
/// writes `(* 0.1 30)` means 3, and IEEE gives 3.0000000000000004. Relative,
/// so it scales with the magnitude and never admits an actual half.
const integer_tolerance: f64 = 1e-9;

pub fn narrowF64(n: f64) NarrowError!u32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return error.NotFinite;
    const r = @round(n);
    if (@abs(n - r) > integer_tolerance * @max(1.0, @abs(n))) return error.NotAnInteger;
    if (r < 0) return error.Negative;
    if (r > @as(f64, std.math.maxInt(u32))) return error.AboveU32;
    return @intFromFloat(r);
}

fn narrowI64(i: i64) NarrowError!u32 {
    if (i < 0) return error.Negative;
    if (i > std.math.maxInt(u32)) return error.AboveU32;
    return @intCast(i);
}

fn narrowU64(u: u64) NarrowError!u32 {
    if (u > std.math.maxInt(u32)) return error.AboveU32;
    return @intCast(u);
}

/// Evaluate an arbitrary value node to f64 against `env` — the sibling of
/// `evalNodeU32` for slots whose wire form is a float (clear colors, blend
/// constants, inline float32 data) or whose call site does its own narrowing.
pub fn evalNodeF64(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: Schema.Schema,
    env: *const Env,
    idx: NodeIndex,
) EvalError!f64 {
    var result = Expr.eval(gpa, tree, idx, env, schema) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EmitError,
    };
    defer result.deinit();
    return switch (result.value) {
        .number => |n| n,
        .integer_i64 => |i| @floatFromInt(i),
        .integer_u64 => |u| @floatFromInt(u),
        else => error.EmitError,
    };
}

/// Why a numeric node did not evaluate — the evaluator's own error, for the
/// failure-path message (`Emitter.refuseNumeric`); null when it evaluated,
/// just not to a number. The failure path is the only caller, so the second
/// evaluation is free.
pub fn evalFailure(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: Schema.Schema,
    env: *const Env,
    idx: NodeIndex,
) ?Expr.Error {
    var result = Expr.eval(gpa, tree, idx, env, schema) catch |e| return e;
    result.deinit();
    return null;
}

/// The first symbol in an expression subtree that neither `env` nor a `let`
/// binder inside the expression binds — the name behind `UnknownBinding`,
/// which the evaluator raises without carrying it. Heads are not visited
/// (`FormHeader.children` holds the arguments only). Bounded: an explicit
/// stack of 64 and a `let` binder table of 16; an expression past either
/// answers null and the caller falls back to the nameless message.
pub fn firstUnboundSymbol(tree: *const Ast.Tree, env: *const Env, root: NodeIndex) ?[]const u8 {
    std.debug.assert(tree.tagOf(root) != .kvpair); // pre: a value node, not a `:key value` pair
    std.debug.assert(tree.tagOf(root) != .keyword); // pre: keywords are never expressions
    var stack: [64]NodeIndex = undefined;
    var sp: usize = 1;
    stack[0] = root;
    var let_names: [16][]const u8 = undefined;
    var lets: usize = 0;
    for (0..4096) |_| {
        if (sp == 0) return null;
        sp -= 1;
        const idx = stack[sp];
        switch (tree.tagOf(idx)) {
            .symbol => {
                const name = tree.symbolText(idx);
                if (env.lookup(name) != null) continue;
                var bound = false;
                for (let_names[0..lets]) |ln| {
                    if (std.mem.eql(u8, ln, name)) bound = true;
                }
                if (!bound) return name;
            },
            .form => {
                const hdr = tree.formHeader(idx);
                // `(let [x 4 y 5] body)`: the even elements of the binder vector
                // are names, not references.
                if (std.mem.eql(u8, hdr.head, "let") and hdr.children.len > 0 and tree.tagOf(hdr.children[0]) == .vector) {
                    const elems = tree.vectorElements(hdr.children[0]);
                    var i: usize = 0;
                    while (i < elems.len) : (i += 2) {
                        if (tree.tagOf(elems[i]) != .symbol) continue;
                        if (lets == let_names.len) return null;
                        let_names[lets] = tree.symbolText(elems[i]);
                        lets += 1;
                    }
                }
                for (hdr.children) |c| {
                    if (sp == stack.len) return null;
                    stack[sp] = c;
                    sp += 1;
                }
            },
            .vector => {
                for (tree.vectorElements(idx)) |c| {
                    if (sp == stack.len) return null;
                    stack[sp] = c;
                    sp += 1;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Evaluate an arbitrary value node to u32 against `env`. A value that does
/// not fit is the `NarrowError` tag that says why (see `narrowF64`).
pub fn evalNodeU32(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: Schema.Schema,
    env: *const Env,
    idx: NodeIndex,
) EvalError!u32 {
    var result = Expr.eval(gpa, tree, idx, env, schema) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EmitError,
    };
    defer result.deinit();
    return switch (result.value) {
        .number => |n| narrowF64(n),
        .integer_i64 => |i| narrowI64(i),
        .integer_u64 => |u| narrowU64(u),
        else => error.EmitError,
    };
}

/// `(define …)` values only: `evalNodeF64` that keeps SJON's `UnknownBinding`
/// apart from the other evaluation failures, because for a constant it is
/// not (yet) a failure — a constant may name a constant declared after it,
/// and `Emitter.buildEnv` resolves the set to a fixed point, retrying the
/// ones that named something not bound yet. Everything else is `EmitError`.
pub const DefineEvalError = error{ OutOfMemory, UnknownBinding, EmitError };
pub fn evalDefineValue(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: Schema.Schema,
    env: *const Env,
    idx: NodeIndex,
) DefineEvalError!f64 {
    var result = Expr.eval(gpa, tree, idx, env, schema) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownBinding => error.UnknownBinding,
        else => error.EmitError,
    };
    defer result.deinit();
    return switch (result.value) {
        .number => |n| n,
        .integer_i64 => |i| @floatFromInt(i),
        .integer_u64 => |u| @floatFromInt(u),
        else => error.EmitError,
    };
}

/// Map a builtin write-buffer data source symbol to its (kind, size) encoding.
/// Returns null for symbols that are not builtins (i.e. plain `(data …)` refs).
pub const DataSource = union(enum) {
    /// time/canvas uniform → writeTimeUniform(buffer, offset, size)
    time_uniform: u16,
    /// pointer/input uniform → writePointerUniform(buffer, offset, size)
    pointer_uniform: u16,
};

pub fn mapDataSource(name: []const u8) ?DataSource {
    if (std.mem.eql(u8, name, "pngine-inputs")) return .{ .time_uniform = 16 };
    if (std.mem.eql(u8, name, "scene-time-inputs")) return .{ .time_uniform = 12 };
    if (std.mem.eql(u8, name, "pointer-inputs")) return .{ .pointer_uniform = 48 };
    return null;
}

/// Map a `(wasm-call :args …)` builtin symbol to its runtime WASM arg type — the
/// kebab-case SJON spelling of the legacy `canvas.width`/`time.total` builtin refs.
/// Returns null for non-builtins (numeric literals, encoded as literal_f32/u32 by
/// the caller). Runtime types carry zero value bytes; the runtime supplies the
/// value each frame (canvas size / elapsed time), so the encoding is just the tag.
pub const WasmArgType = types.WasmArgType;
pub fn mapWasmArgType(sym: []const u8) ?WasmArgType {
    if (std.mem.eql(u8, sym, "canvas-width")) return .canvas_width;
    if (std.mem.eql(u8, sym, "canvas-height")) return .canvas_height;
    if (std.mem.eql(u8, sym, "time-total")) return .time_total;
    if (std.mem.eql(u8, sym, "time-delta")) return .time_delta;
    return null;
}

/// Byte size of a static `(wasm-data …)` generator's WGSL `:returns` type. Handles
/// `array<elem, N>` (N × element size) on top of the scalar/vec/mat catalog in
/// `WasmReturnType.byteSize` — the runtime `(wasm-call …)` path only ever returns the
/// catalog types (mat4x4, …), but mesh generators return `array<f32, N>`. Mirrors
/// the legacy `resources.parseWgslReturnType`. Returns null on an unparseable type.
pub fn wgslReturnByteSize(type_str: []const u8) ?u32 {
    if (std.mem.startsWith(u8, type_str, "array<")) {
        const comma = std.mem.lastIndexOfScalar(u8, type_str, ',') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, type_str, comma, '>') orelse return null;
        const count = std.fmt.parseInt(u32, std.mem.trim(u8, type_str[comma + 1 .. close], " \t"), 10) catch return null;
        const elem = std.mem.trim(u8, type_str["array<".len..comma], " \t");
        return count * (types.WasmReturnType.byteSize(elem) orelse return null);
    }
    return types.WasmReturnType.byteSize(type_str);
}

/// CANVAS texture sentinel id for `view=context-current-texture`. Matches the
/// legacy emitter's `CANVAS_TEXTURE_ID`.
pub const CANVAS_TEXTURE_ID: u16 = 0xFFFE;
/// "No texture" sentinel (no depth / no resolve target).
pub const NO_TEXTURE_ID: u16 = 0xFFFF;

// ---- Phase 2a: texture / shape / index helpers ----

const types = @import("types");
pub const TextureFormat = types.TextureFormat;
pub const TextureUsage = types.TextureUsage;
pub const BufferUsage = types.BufferUsage;
pub const FilterMode = types.FilterMode;
pub const AddressMode = types.AddressMode;

/// Map a `texture-format` symbol to its enum. The encoded texture descriptor
/// bytes are pinned raw by the golden traces (test-sjon-golden).
/// `preferred-canvas-format` (the hyphenated SJON spelling) maps explicitly.
pub fn mapTextureFormat(sym: []const u8) TextureFormat {
    if (std.mem.eql(u8, sym, "preferred-canvas-format")) return .preferred_canvas_format;
    return TextureFormat.fromString(sym);
}

/// Map a `filter-mode` symbol to its enum (absent → `nearest`, as
/// GPUSamplerDescriptor's magFilter/minFilter default; spec/09 step D).
pub fn mapFilterMode(sym: ?[]const u8) FilterMode {
    if (sym) |s| if (std.mem.eql(u8, s, "linear")) return .linear;
    return .nearest;
}

/// Map an `address-mode` symbol to its enum (default `clamp-to-edge`).
pub fn mapAddressMode(sym: ?[]const u8) AddressMode {
    if (sym) |s| {
        if (std.mem.eql(u8, s, "repeat")) return .repeat;
        if (std.mem.eql(u8, s, "mirror-repeat")) return .mirror_repeat;
    }
    return .clamp_to_edge;
}

/// Map a `compare-function` symbol to the runtime compare id (0..7), or null.
pub fn mapCompareFunction(sym: []const u8) ?u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "never", 0 },   .{ "less", 1 },      .{ "equal", 2 },         .{ "less-equal", 3 },
        .{ "greater", 4 }, .{ "not-equal", 5 }, .{ "greater-equal", 6 }, .{ "always", 7 },
    });
    return map.get(sym);
}

/// Set one `texture-usage` bit on the bitfield (mirrors the legacy
/// `parseTextureUsage`, which yields the same packed byte from UPPER_CASE flags).
pub fn applyTextureUsage(usage: *TextureUsage, sym: []const u8) void {
    if (std.mem.eql(u8, sym, "copy-src")) usage.copy_src = true;
    if (std.mem.eql(u8, sym, "copy-dst")) usage.copy_dst = true;
    if (std.mem.eql(u8, sym, "texture-binding")) usage.texture_binding = true;
    if (std.mem.eql(u8, sym, "storage-binding")) usage.storage_binding = true;
    if (std.mem.eql(u8, sym, "render-attachment")) usage.render_attachment = true;
}

/// Set one `buffer-usage` bit on the bitfield (the buffer analog of
/// `applyTextureUsage`; mirrors the legacy `parseBufferUsage`). An unknown symbol
/// is a no-op, so a `:usage` list with a stray flag emits the bits it recognized.
pub fn applyUsage(usage: *BufferUsage, sym: []const u8) void {
    if (std.mem.eql(u8, sym, "vertex")) usage.vertex = true;
    if (std.mem.eql(u8, sym, "index")) usage.index = true;
    if (std.mem.eql(u8, sym, "uniform")) usage.uniform = true;
    if (std.mem.eql(u8, sym, "storage")) usage.storage = true;
    if (std.mem.eql(u8, sym, "copy-dst")) usage.copy_dst = true;
    if (std.mem.eql(u8, sym, "copy-src")) usage.copy_src = true;
    if (std.mem.eql(u8, sym, "indirect")) usage.indirect = true;
    if (std.mem.eql(u8, sym, "query-resolve")) usage.query_resolve = true;
    if (std.mem.eql(u8, sym, "map-read")) usage.map_read = true;
    if (std.mem.eql(u8, sym, "map-write")) usage.map_write = true;
}

/// Map an `index-format` symbol to the runtime format id (0 = uint16, 1 = uint32).
pub fn mapIndexFormat(sym: []const u8) u8 {
    return if (std.mem.eql(u8, sym, "uint32")) 1 else 0;
}

/// Map a `visibility` shader-stage symbol to its WebGPU bit (vertex 0x01 /
/// fragment 0x02 / compute 0x04), matching the legacy `parseVisibilityFlags`
/// (resources.zig). The caller ORs the bits of a `:visibility [vertex fragment]`
/// list into the bind-group-layout entry's visibility mask.
pub fn mapVisibility(sym: []const u8) u8 {
    if (std.mem.eql(u8, sym, "vertex")) return 0x01;
    if (std.mem.eql(u8, sym, "fragment")) return 0x02;
    if (std.mem.eql(u8, sym, "compute")) return 0x04;
    return 0;
}

/// Map a `buffer-binding-type` symbol to its WebGPU JSON string. The SJON symbols
/// are already the WebGPU spellings, so this is identity over the member-set —
/// written explicitly to mirror the legacy `buildBufferBindingJson` (which emits
/// the source value verbatim) and to give a single defaulting point for an
/// unknown symbol.
pub fn mapBufferBindingType(sym: []const u8) []const u8 {
    if (std.mem.eql(u8, sym, "storage")) return "storage";
    if (std.mem.eql(u8, sym, "read-only-storage")) return "read-only-storage";
    return "uniform";
}

/// The three non-buffer BGL resource types → their WebGPU JSON strings. Like
/// `mapBufferBindingType`, the SJON symbols are already the WebGPU spellings, so
/// each is identity over its member-set with a single default for unknown input.
pub fn mapSamplerBindingType(sym: []const u8) []const u8 {
    if (std.mem.eql(u8, sym, "non-filtering")) return "non-filtering";
    if (std.mem.eql(u8, sym, "comparison")) return "comparison";
    return "filtering";
}
pub fn mapTextureSampleType(sym: []const u8) []const u8 {
    if (std.mem.eql(u8, sym, "unfilterable-float")) return "unfilterable-float";
    if (std.mem.eql(u8, sym, "depth")) return "depth";
    if (std.mem.eql(u8, sym, "sint")) return "sint";
    if (std.mem.eql(u8, sym, "uint")) return "uint";
    return "float";
}
pub fn mapStorageTextureAccess(sym: []const u8) []const u8 {
    if (std.mem.eql(u8, sym, "read-only")) return "read-only";
    if (std.mem.eql(u8, sym, "read-write")) return "read-write";
    return "write-only";
}

/// GPUTextureDimension spelling → the descriptor encoder's code (0 = 1d, 1 = 2d,
/// 2 = 3d). Since SJON 1.3 the schema spells the members as WebGPU does (`1d`,
/// `2d`, `3d`; §366) — read them with `Reader.memberSpelling`. Null for anything
/// that is not a member: the validator rejected it, so the emitter treats null
/// on a present key as an internal error, never a default.
pub fn textureDimensionCode(spelling: []const u8) ?u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "1d", 0 },
        .{ "2d", 1 },
        .{ "3d", 2 },
    });
    return map.get(spelling);
}

/// GPUTextureViewDimension spelling → the descriptor encoder's code (0 = 1d,
/// 1 = 2d, 2 = 2d-array, 3 = cube, 4 = cube-array, 5 = 3d) — the inverse of
/// `viewDimensionString`. Same null contract as `textureDimensionCode`.
pub fn viewDimensionCode(spelling: []const u8) ?u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "1d", 0 },
        .{ "2d", 1 },
        .{ "2d-array", 2 },
        .{ "cube", 3 },
        .{ "cube-array", 4 },
        .{ "3d", 5 },
    });
    return map.get(spelling);
}

/// View-dimension code (0..5, see `viewDimensionCode`) → the WebGPU string the
/// BGL descriptor JSON carries so gpu.js can pass it straight to
/// createBindGroupLayout. Out-of-range → "2d" (the WebGPU default).
pub fn viewDimensionString(dim: u32) []const u8 {
    return switch (dim) {
        0 => "1d",
        2 => "2d-array",
        3 => "cube",
        4 => "cube-array",
        5 => "3d",
        else => "2d",
    };
}

/// Map a `shape …` head to the `shapes.ShapeType` it selects, or null if the
/// head is not a shape generator.
pub fn shapeTypeFromHead(head: []const u8) ?ShapeType {
    const map = std.StaticStringMap(ShapeType).initComptime(.{
        .{ "cube", .cube },
        .{ "plane", .plane },
        .{ "sphere", .sphere },
        .{ "torus", .torus },
        .{ "truncated-cone", .truncated_cone },
        .{ "cylinder", .cylinder },
        .{ "teapot", .teapot },
        .{ "dragon", .dragon },
    });
    return map.get(head);
}

const ShapeType = @import("shapes").ShapeType;

/// Math constants substituted into WGSL bodies, mirroring the legacy
/// `dsl/emitter/shaders.zig` `math_constants` table (TAU before PI for the
/// longest-match rule). PNGine lets shader authors write these symbolically;
/// the emitter inlines the literal so the WGSL the GPU sees needs no PNGine
/// preamble. The inlined WGSL is pinned by the golden traces (which compare
/// normalized WGSL).
const math_constants = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "TAU", .value = "6.283185307179586" },
    .{ .name = "PI", .value = "3.141592653589793" },
    .{ .name = "E", .value = "2.718281828459045" },
};

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Whole-word match of `name` at `pos`, excluding declarations (`name : type`),
/// mirroring the legacy `matchesIdentifier`. Bounded whitespace scan.
fn matchesConstant(code: []const u8, pos: usize, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    if (pos + name.len > code.len) return false;
    if (!std.mem.eql(u8, code[pos..][0..name.len], name)) return false;
    const before_ok = pos == 0 or !isIdentChar(code[pos - 1]);
    const after_ok = pos + name.len >= code.len or !isIdentChar(code[pos + name.len]);
    if (!before_ok or !after_ok) return false;
    // A following ':' marks a declaration (`const PI: f32`) — don't substitute.
    var check = pos + name.len;
    for (0..16) |_| {
        if (check >= code.len or (code[check] != ' ' and code[check] != '\t')) break;
        check += 1;
    }
    return !(check < code.len and code[check] == ':');
}

/// Substitute whole-word math constants (PI/TAU/E) into WGSL, matching the legacy
/// emitter so `.sjon` shaders compile to the same module the GPU executes.
/// Returns an owned copy the caller frees, or null when no constant is present
/// (the common case → caller emits the original slice, no allocation).
pub fn substituteMathConstants(gpa: std.mem.Allocator, code: []const u8) !?[]u8 {
    std.debug.assert(code.len < std.math.maxInt(u32));
    var present = false;
    for (0..code.len) |i| {
        for (math_constants) |c| {
            if (matchesConstant(code, i, c.name)) {
                present = true;
                break;
            }
        }
        if (present) break;
    }
    if (!present) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    outer: while (i < code.len) {
        for (math_constants) |c| {
            if (matchesConstant(code, i, c.name)) {
                try out.appendSlice(gpa, c.value);
                i += c.name.len;
                continue :outer;
            }
        }
        try out.append(gpa, code[i]);
        i += 1;
    }
    std.debug.assert(out.items.len >= code.len);
    return try out.toOwnedSlice(gpa);
}

// ============================================================================
// Tests
// ============================================================================
