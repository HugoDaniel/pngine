#!/usr/bin/env node
/**
 * Test embedded WASM executor in Node.js
 *
 * Usage: node scripts/test-executor.js <payload.pngb>
 *
 * This script:
 * 1. Loads a PNGB payload with embedded executor
 * 2. Extracts and instantiates the executor WASM
 * 3. Copies bytecode and data section to WASM memory
 * 4. Calls init() and frame()
 * 5. Dumps the resulting command buffer
 */

import fs from 'fs';
import path from 'path';

// Command opcodes (matches runner.zig)
const CMD_NAMES = {
    0x01: 'CREATE_BUFFER',
    0x02: 'CREATE_TEXTURE',
    0x03: 'CREATE_SAMPLER',
    0x04: 'CREATE_SHADER',
    0x05: 'CREATE_RENDER_PIPELINE',
    0x06: 'CREATE_COMPUTE_PIPELINE',
    0x07: 'CREATE_BIND_GROUP',
    0x08: 'CREATE_TEXTURE_VIEW',
    0x10: 'BEGIN_RENDER_PASS',
    0x11: 'BEGIN_COMPUTE_PASS',
    0x12: 'SET_PIPELINE',
    0x13: 'SET_BIND_GROUP',
    0x14: 'SET_VERTEX_BUFFER',
    0x15: 'DRAW',
    0x16: 'DRAW_INDEXED',
    0x17: 'END_PASS',
    0x18: 'DISPATCH',
    0x19: 'SET_INDEX_BUFFER',
    0x20: 'WRITE_BUFFER',
    0x21: 'WRITE_TIME_UNIFORM',
    0x30: 'INIT_WASM_MODULE',
    0x31: 'CALL_WASM_FUNC',
    0x33: 'CREATE_TYPED_ARRAY',
    0x34: 'FILL_RANDOM',
    0xF0: 'SUBMIT',
    0xFF: 'END',
};

async function main() {
    const args = process.argv.slice(2);
    if (args.length === 0) {
        console.log('Usage: node test-executor.js <payload.pngb> [--time=T] [--width=W] [--height=H]');
        process.exit(1);
    }

    const payloadPath = args[0];
    let time = 0.0, width = 512, height = 512;

    for (const arg of args.slice(1)) {
        if (arg.startsWith('--time=')) time = parseFloat(arg.slice(7));
        if (arg.startsWith('--width=')) width = parseInt(arg.slice(8));
        if (arg.startsWith('--height=')) height = parseInt(arg.slice(9));
    }

    // Load payload
    const payload = fs.readFileSync(payloadPath);
    console.log(`Loaded ${payloadPath}: ${payload.length} bytes`);

    // Parse header
    const magic = payload.slice(0, 4).toString('ascii');
    if (magic !== 'PNGB') {
        console.error('Error: Not a PNGB file');
        process.exit(1);
    }

    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const version = view.getUint16(4, true);
    const flags = view.getUint16(6, true);
    const hasEmbeddedExecutor = (flags & 0x01) !== 0;

    console.log(`PNGB v${version}, flags: embedded=${hasEmbeddedExecutor}`);

    if (!hasEmbeddedExecutor) {
        console.error('Error: No embedded executor');
        process.exit(1);
    }

    const executorOffset = view.getUint32(12, true);
    const executorLength = view.getUint32(16, true);
    const stringTableOffset = view.getUint32(20, true);
    const dataSectionOffset = view.getUint32(24, true);

    console.log(`Executor: offset=${executorOffset}, len=${executorLength}`);

    // Extract executor WASM
    const executorWasm = payload.slice(executorOffset, executorOffset + executorLength);

    // Set up WASM imports
    let memory;
    const importObject = {
        env: {
            log: (ptr, len) => {
                const bytes = new Uint8Array(memory.buffer, ptr, len);
                const str = new TextDecoder().decode(bytes);
                console.log('[log]', str);
            }
        }
    };

    // Instantiate WASM
    const result = await WebAssembly.instantiate(executorWasm, importObject);
    const exports = result.instance.exports;
    memory = exports.memory;

    console.log(`WASM memory: ${memory.buffer.byteLength} bytes`);

    // Copy bytecode
    const bytecodePtr = exports.getBytecodePtr();
    const wasmBytes = new Uint8Array(memory.buffer);
    wasmBytes.set(payload, bytecodePtr);
    exports.setBytecodeLen(payload.length);
    console.log(`Bytecode copied: ${payload.length} bytes at 0x${bytecodePtr.toString(16)}`);

    // Copy data section
    const dataPtr = exports.getDataPtr();
    const dataSection = payload.slice(dataSectionOffset);
    wasmBytes.set(dataSection, dataPtr);
    exports.setDataLen(dataSection.length);
    console.log(`Data section copied: ${dataSection.length} bytes at 0x${dataPtr.toString(16)}`);

    // Call init()
    console.log('\nCalling init()...');
    const initResult = exports.init();
    if (initResult !== 0) {
        console.error(`init() failed with code ${initResult}`);
        process.exit(1);
    }

    // Dump init command buffer
    const initCmdPtr = exports.getCommandPtr();
    const initCmdLen = exports.getCommandLen();
    console.log(`\n[init] Command buffer: ${initCmdLen} bytes`);
    dumpCommandBuffer(memory.buffer, initCmdPtr, initCmdLen);

    // Call frame()
    console.log(`\nCalling frame(${time}, ${width}, ${height})...`);
    const frameResult = exports.frame(time, width, height);
    if (frameResult !== 0) {
        console.error(`frame() returned ${frameResult}`);
    }

    // Dump frame command buffer
    const frameCmdPtr = exports.getCommandPtr();
    const frameCmdLen = exports.getCommandLen();
    console.log(`\n[frame] Command buffer: ${frameCmdLen} bytes`);
    dumpCommandBuffer(memory.buffer, frameCmdPtr, frameCmdLen);

    console.log('\nDone!');
}

function dumpCommandBuffer(buffer, ptr, len) {
    if (len < 8) {
        console.log('  (empty)');
        return;
    }

    const view = new DataView(buffer, ptr, len);
    const totalLen = view.getUint32(0, true);
    const cmdCount = view.getUint16(4, true);
    const flags = view.getUint16(6, true);

    console.log(`  total_len=${totalLen}, cmds=${cmdCount}, flags=0x${flags.toString(16)}`);

    let pos = 8;
    for (let i = 0; i < cmdCount && pos < len; i++) {
        const cmd = view.getUint8(pos);
        const name = CMD_NAMES[cmd] || `UNKNOWN(0x${cmd.toString(16)})`;
        console.log(`  [${i.toString().padStart(3)}] 0x${cmd.toString(16).padStart(2, '0')} ${name}`);

        // Simple size estimation (1 byte for unknown commands)
        pos += getCmdSize(cmd);

        if (cmd === 0xFF) break; // END
    }
}

function getCmdSize(cmd) {
    switch (cmd) {
        case 0x01: return 1 + 2 + 4 + 1; // CREATE_BUFFER
        case 0x02: case 0x03: case 0x04: return 1 + 2 + 4 + 4;
        case 0x05: case 0x06: return 1 + 2 + 4 + 4;
        case 0x07: case 0x08: return 1 + 2 + 2 + 4 + 4;
        case 0x10: return 1 + 2 + 1 + 1 + 2;
        case 0x11: case 0x17: case 0xF0: case 0xFF: return 1;
        case 0x12: return 1 + 2;
        case 0x13: case 0x14: case 0x19: return 1 + 1 + 2;
        case 0x15: return 1 + 4 + 4 + 4 + 4;
        case 0x16: return 1 + 4 + 4 + 4 + 4 + 4;
        case 0x18: return 1 + 4 + 4 + 4;
        case 0x20: return 1 + 2 + 4 + 4 + 4;
        case 0x21: return 1 + 2 + 4 + 2;
        case 0x30: return 1 + 2 + 4 + 4;
        case 0x31: return 1 + 2 + 2 + 4 + 4 + 4 + 4;
        case 0x33: return 1 + 2 + 4 + 1;
        case 0x34: return 1 + 2;
        default: return 1;
    }
}

main().catch(err => {
    console.error('Error:', err);
    process.exit(1);
});
