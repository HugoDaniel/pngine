# Refactoring Plan: Alignment with Zig Mastery Guidelines

This document outlines the plan to bring the `pngine` codebase into full compliance with the [Zig Mastery Guidelines](../llm/mastery/zig/ZIG_MASTERY.md) and [Elite Zig Persona](../llm/mastery/zig/ELITE_ZIG_PERSONA.md).

## Summary of Violations

1.  **Naming Conventions**: Pervasive use of `camelCase` for functions (e.g., `createBuffer`) instead of the mandated `snake_case` (e.g., `create_buffer`).
2.  **Function Size**: Core functions (Lexer, Parser) exceed the 70-line limit.
3.  **Type Strictness**: `usize` used for bytecode program counter (`pc`) instead of explicit `u32`.

## Phase 1: Type Strictness (Low Effort, High Value)

**Objective**: Enforce explicit sizing for the bytecode execution pointer.

*   **Target**: `src/executor/dispatcher.zig`
*   **Changes**:
    *   Change `pc: usize` to `pc: u32` in `Dispatcher` struct.
    *   Update `readByte`, `readVarint`, `step`, `executeFromPC` to use `u32`.
    *   Ensure the 1MB bytecode limit assertion (`assert(module.bytecode.len <= 1024 * 1024)`) is strictly enforced at init to guarantee `u32` safety.

## Phase 2: Function Decomposition (Medium Effort)

**Objective**: Reduce function complexity and size to < 70 lines where feasible, without sacrificing the performance benefits of the labeled switch pattern.

### 2.1 Lexer Refactoring
*   **Target**: `src/dsl/Lexer.zig` -> `next()`
*   **Challenge**: The function uses a labeled switch for performance (zero function call overhead). Extracting logic naively breaks this.
*   **Strategy**: Extract complex *terminal* logic into private helpers. Keep the state transition switch intact but lightweight.
    *   Extract number parsing logic (hex vs decimal) into `lexNumber()`.
    *   Extract string literal parsing into `lexString()`.
    *   Extract identifier/keyword logic into `lexIdentifier()`.
    *   The main `next()` switch should primarily handle the initial character dispatch and state transitions.

### 2.2 Parser Refactoring
*   **Target**: `src/dsl/Parser.zig` -> `parseValue()`
*   **Strategy**:
    *   The function currently handles simple values, expressions, and nested structures.
    *   Extract the "Task Stack" processing loop into a dedicated `processParseTasks()` function.
    *   Extract the "Simple Value" switch (string, number, boolean, identifier) into `parseSimpleValueOrExpression()`.

## Phase 3: Naming Convention Refactor (High Effort)

**Objective**: Rename all `camelCase` functions to `snake_case`. This is a breaking change for internal APIs.

**Order of Operations**:

### 3.1 GPU Backend Interface (The Contract)
*   **Target**: `src/executor/dispatcher.zig` (`Backend` interface validation)
*   **Changes**: Update expected method names in `Backend(T).validate()`:
    *   `createBuffer` -> `create_buffer`
    *   `beginRenderPass` -> `begin_render_pass`
    *   `setPipeline` -> `set_pipeline`
    *   ...and all others.

### 3.2 GPU Implementations
*   **Targets**:
    *   `src/gpu/native_gpu.zig`
    *   `src/gpu/dawn_gpu.zig`
    *   `src/executor/mock_gpu.zig`
    *   `src/executor/wasm_gpu.zig`
*   **Action**: Rename all public methods to match the new `Backend` interface.

### 3.3 Executor & Dispatcher
*   **Target**: `src/executor/dispatcher.zig`
*   **Action**: Update `step()` to call the new `snake_case` backend methods.

### 3.4 DSL & Bytecode
*   **Targets**:
    *   `src/dsl/Emitter.zig`: Rename methods like `createBuffer` -> `create_buffer`.
    *   `src/bytecode/emitter.zig`: Rename methods.
    *   `src/bytecode/assembler.zig`: Update calls to emitter.
    *   `src/dsl/Parser.zig`: Rename `parseRoot` -> `parse_root`, `parseMacro` -> `parse_macro`.
    *   `src/dsl/Lexer.zig`: Rename `getTokenText` -> `get_token_text`.

### 3.5 CLI & Main
*   **Targets**:
    *   `src/cli.zig`: Rename `printUsage` -> `print_usage`.
    *   `src/cli/*.zig`: Update calls to library functions.
    *   `src/main.zig`: Update exports and high-level functions (`compileSlice` -> `compile_slice`).

## Phase 4: Verification

1.  **Build**: Run `zig build` to ensure all renames are caught by the compiler.
2.  **Test**: Run `zig build test-standalone` to verify logic integrity.
3.  **Lint**: Verify no `camelCase` function declarations remain in `src/`.

## Execution Notes

*   **Atomic Commits**: Perform Phase 1 and 2 as separate commits. Phase 3 should be broken down by layer (Interface -> Impl -> Consumer) if possible, but might require a "big bang" commit for the GPU interface to keep the build passing.
*   **Preserve Logic**: Ensure refactoring (renaming/extracting) does not alter logic.
