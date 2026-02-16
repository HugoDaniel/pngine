import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";

import { pngine as viewerPngine } from "./viewer-init.js";
import { pngine as devPngine, destroy as devDestroy } from "./init.js";

function buildPngbPayload({ embeddedExecutor }) {
  const executor = embeddedExecutor
    ? new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
    : new Uint8Array(0);
  const payload = new Uint8Array(40 + executor.length);
  const view = new DataView(payload.buffer);

  // magic
  payload[0] = 0x50; // P
  payload[1] = 0x4e; // N
  payload[2] = 0x47; // G
  payload[3] = 0x42; // B

  view.setUint16(4, 0, true); // version v0
  view.setUint16(6, embeddedExecutor ? 0x01 : 0x00, true); // flags
  payload[8] = 0x01; // plugins: core

  const executorOffset = embeddedExecutor ? 40 : 0;
  const sectionOffset = 40 + executor.length;
  view.setUint32(12, executorOffset, true); // executor_offset
  view.setUint32(16, executor.length, true); // executor_length
  view.setUint32(20, sectionOffset, true); // string table offset
  view.setUint32(24, sectionOffset, true); // data section offset
  view.setUint32(28, sectionOffset, true); // wgsl table offset
  view.setUint32(32, sectionOffset, true); // uniform table offset
  view.setUint32(36, sectionOffset, true); // animation table offset

  if (embeddedExecutor) {
    payload.set(executor, 40);
  }

  return payload;
}

function makeCanvas() {
  return {
    transferControlToOffscreen() {
      return { width: 320, height: 200 };
    },
  };
}

class ReadyWorker {
  static instances = [];

  constructor() {
    this.onmessage = null;
    this.onerror = null;
    this.messages = [];
    this.terminated = false;
    ReadyWorker.instances.push(this);
  }

  postMessage(data) {
    this.messages.push(data);
    if (data?.type === "init") {
      queueMicrotask(() => {
        this.onmessage?.({
          data: { type: "ready", width: 320, height: 200, frameCount: 1 },
        });
      });
    }
  }

  terminate() {
    this.terminated = true;
  }
}

const GLOBAL_KEYS = [
  "Worker",
  "window",
  "HTMLImageElement",
  "HTMLCanvasElement",
];

const MISSING = Symbol("missing");
let savedGlobals = null;

beforeEach(() => {
  savedGlobals = new Map();
  for (const key of GLOBAL_KEYS) {
    if (Object.prototype.hasOwnProperty.call(globalThis, key)) {
      savedGlobals.set(key, globalThis[key]);
    } else {
      savedGlobals.set(key, MISSING);
    }
  }

  globalThis.window = { location: { href: "http://localhost/" } };
  globalThis.HTMLImageElement = class HTMLImageElementMock {};
  globalThis.HTMLCanvasElement = class HTMLCanvasElementMock {};
});

afterEach(() => {
  for (const key of GLOBAL_KEYS) {
    const prev = savedGlobals.get(key);
    if (prev === MISSING) {
      delete globalThis[key];
    } else {
      globalThis[key] = prev;
    }
  }
});

describe("runtime profile contract", () => {
  it("viewer rejects no-executor payloads before worker startup", async () => {
    let workerCreated = false;
    globalThis.Worker = class FailingWorker {
      constructor() {
        workerCreated = true;
      }
    };

    const payload = buildPngbPayload({ embeddedExecutor: false });
    const canvas = makeCanvas();

    await assert.rejects(
      viewerPngine(payload, { canvas }),
      /No embedded executor in payload/
    );
    assert.equal(workerCreated, false);
  });

  it("dev accepts no-executor payloads when wasmUrl is provided", async () => {
    ReadyWorker.instances.length = 0;
    globalThis.Worker = ReadyWorker;

    const payload = buildPngbPayload({ embeddedExecutor: false });
    const canvas = makeCanvas();

    const instance = await devPngine(payload, {
      canvas,
      wasmUrl: "/runtime/pngine.wasm",
    });

    assert.equal(ReadyWorker.instances.length, 1);
    const worker = ReadyWorker.instances[0];
    assert.equal(worker.messages.length > 0, true);

    const initMessage = worker.messages[0];
    assert.equal(initMessage.type, "init");
    assert.equal(initMessage.wasmUrl, "http://localhost/runtime/pngine.wasm");

    devDestroy(instance);
  });
});
