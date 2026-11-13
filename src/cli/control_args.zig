//! `--control name=value` (frame program plan §6.3, §6.6, §11).
//!
//! One spelling, three consumers: `render --control`, `inspect --control`, and
//! (through the same rules) `inspect --deep`. The flag is repeatable; each
//! assignment is validated here BEFORE the command prints or writes anything,
//! and resolved against the payload's PUBLIC name block:
//! `pngine.uniform_table.controlSlotByName` — no private copy of the control
//! names lives in the CLI.
//!
//! The three rules of plan §6.6 live on the application side, not here:
//! values are written after `init()` and before the frame body, and slot 0
//! (`time`) is never writable through this flag (`-t`/`--time` is the time
//! channel). The reference dispatcher gets `set_control`; the WAMR paths get
//! one f32 at `getControlPtr() + 4 * slot`.

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;

/// A document declares at most 64 controls (plan §4.1); so does one `--control`
/// run. A repeat of the same name still spends an entry, and the last one wins
/// at application time — the ordinary "later flag wins" reading.
pub const MAX_CONTROLS: usize = pngine.opcodes.MAX_CONTROLS;

/// One parsed `--control name=value` before the payload is known.
pub const Assignment = struct {
    name: []const u8,
    value: f32,
};

/// The parsed `--control` flags in command-line order.
pub const List = struct {
    items: [MAX_CONTROLS]Assignment = undefined,
    len: usize = 0,

    pub fn slice(self: *const List) []const Assignment {
        return self.items[0..self.len];
    }
};

/// One assignment after `resolve()` turned its name into the payload's slot.
pub const Resolved = struct {
    slot: u16,
    value: f32,
};

/// The assignments with their slots, in command-line order.
pub const ResolvedList = struct {
    items: [MAX_CONTROLS]Resolved = undefined,
    len: usize = 0,

    pub fn slice(self: *const ResolvedList) []const Resolved {
        return self.items[0..self.len];
    }
};

/// Parse one `--control` value and append it. Prints the refusal and returns
/// false on: a missing `=`, an empty name, an empty value, a value that is not
/// exactly one number, or a non-finite one (NaN/inf). Those are the plan's five
/// refusals, plus the empty-name spelling.
pub fn addFlag(raw: []const u8, list: *List) bool {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse {
        std.debug.print("Error: invalid --control '{s}': expected name=value\n", .{raw});
        return false;
    };
    const name = raw[0..eq];
    const value_text = raw[eq + 1 ..];
    if (name.len == 0 or value_text.len == 0) {
        std.debug.print("Error: invalid --control '{s}': expected name=value\n", .{raw});
        return false;
    }

    const value = std.fmt.parseFloat(f32, value_text) catch {
        std.debug.print("Error: invalid --control '{s}': value must be one number\n", .{raw});
        return false;
    };
    if (!std.math.isFinite(value)) {
        std.debug.print("Error: invalid --control '{s}': value must be finite\n", .{raw});
        return false;
    }

    if (list.len == list.items.len) {
        std.debug.print("Error: too many --control values (max {d})\n", .{MAX_CONTROLS});
        return false;
    }
    list.items[list.len] = .{ .name = name, .value = value };
    list.len += 1;
    return true;
}

/// Turn every name into its payload slot through the library lookup. Returns
/// the first name the payload does not declare, or null when all resolved.
/// `time` is never in the block, so `--control time=…` is an unknown name here:
/// time has its own flag.
pub fn resolve(module: *const format.Module, list: *const List, out: *ResolvedList) ?[]const u8 {
    out.len = 0;
    for (list.slice()) |assignment| {
        const slot = module.uniforms.controlSlotByName(&module.strings, assignment.name) orelse
            return assignment.name;
        std.debug.assert(out.len < out.items.len);
        out.items[out.len] = .{ .slot = slot, .value = assignment.value };
        out.len += 1;
    }
    return null;
}

/// Print the refusal for a name `resolve()` did not find: the name asked for,
/// then the controls that do exist, in declaration (slot) order. The compiler
/// caps a document at 64, so the list is already short.
pub fn printUnknown(module: *const format.Module, name: []const u8) void {
    std.debug.print("Error: unknown control '{s}'", .{name});

    const slot_count = module.uniforms.control_names.items.len;
    if (slot_count == 0) {
        std.debug.print(" (this document declares no controls)\n", .{});
        return;
    }

    std.debug.print(" (declared controls: ", .{});
    var printed: usize = 0;
    for (1..slot_count + 1) |slot| {
        const control_name = module.uniforms.controlNameBySlot(
            &module.strings,
            @intCast(slot),
        ) orelse continue;
        if (printed > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{control_name});
        printed += 1;
        if (printed == MAX_CONTROLS) break;
    }
    if (printed == 0) std.debug.print("none — every slot is unnamed", .{});
    std.debug.print(")\n", .{});
}

/// Apply resolved values through the reference dispatcher's `set_control`.
/// The declaration phase must already have run, so the dispatcher knows how
/// many controls exist; a name-block slot past that is a malformed payload and
/// is refused instead of silently no-op'd by `set_control`.
pub fn applyToDispatcher(dispatcher: anytype, resolved: []const Resolved) bool {
    for (resolved) |control| {
        const declared = dispatcher.declaredControlCount();
        if (control.slot == 0 or control.slot > declared) {
            std.debug.print(
                "Error: control slot {d} is outside the payload's {d} declared control(s)\n",
                .{ control.slot, declared },
            );
            return false;
        }
        dispatcher.set_control(control.slot, control.value);
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================
