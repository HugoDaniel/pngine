// Sointu audio WASM player
// Instantiates a sointu-compiled WASM module, pre-renders audio,
// and provides synchronized playback via Web Audio API.

/**
 * Deinterleave stereo samples into an AudioBuffer's two channels. int16 samples
 * are scaled to [-1, 1); f32 samples are copied verbatim. Shared with mini.js.
 * @param {AudioBuffer} audioBuffer
 * @param {Int16Array|Float32Array} samples - interleaved L,R,L,R,…
 * @param {number} frames
 * @param {boolean} isInt16
 */
export function deinterleaveStereo(audioBuffer, samples, frames, isInt16) {
  for (let ch = 0; ch < 2; ch++) {
    const data = audioBuffer.getChannelData(ch);
    for (let i = 0; i < frames; i++) {
      data[i] = isInt16 ? samples[i * 2 + ch] / 32768 : samples[i * 2 + ch];
    }
  }
}

/**
 * Create an audio player from a sointu-compiled WASM module.
 *
 * Sointu WASM modules render the entire song during instantiation.
 * After instantiation, audio samples are available in WASM memory.
 * We copy them to an AudioBuffer for playback via Web Audio API.
 *
 * The clock master is whoever calls play()/pause(); this exposes currentTime so
 * a caller can sync a render loop to the audio, never the other way round.
 *
 * @typedef {object} AudioPlayer
 * @property {number} duration            Song length in seconds
 * @property {boolean} playing            Read-only
 * @property {number} currentTime         Read-only, seconds since song start
 * @property {(offset?: number) => void} play
 * @property {() => void} pause
 * @property {() => void} stop
 * @property {(time: number) => void} seek
 * @property {() => void} destroy
 */

/**
 * @param {Uint8Array} wasmBytes - Compiled sointu .wasm module
 * @returns {Promise<AudioPlayer>}
 */
export async function createAudioPlayer(wasmBytes) {
  // Instantiate sointu WASM (renders entire song during instantiation)
  // `m: Math` is sointu's import convention — it calls Math.* directly.
  // Both casts work around lib.dom types, not around a real ambiguity: TS 5.7+
  // makes Uint8Array generic over its buffer, so Uint8Array<ArrayBufferLike> no
  // longer satisfies BufferSource (SharedArrayBuffer is not an ArrayBuffer) and
  // overload resolution falls through to instantiate(Module). `m: Math` is
  // sointu's own import convention — it calls Math.* directly.
  const { instance } = await WebAssembly.instantiate(
    /** @type {BufferSource} */ (/** @type {unknown} */ (wasmBytes)),
    /** @type {WebAssembly.Imports} */ (/** @type {unknown} */ ({ m: Math })),
  );

  // Read audio parameters from sointu exports
  const ex = /** @type {SointuExports} */ (/** @type {unknown} */ (instance.exports));
  const mem = ex.m;
  const bufStart = ex.s.value;
  const bufLen = ex.l.value;
  const isInt16 = ex.t.value === 1;

  const frames = isInt16 ? bufLen / 4 : bufLen / 8;
  const sampleRate = 44100;

  // Read interleaved stereo samples from WASM memory
  const samples = isInt16
    ? new Int16Array(mem.buffer, bufStart, frames * 2)
    : new Float32Array(mem.buffer, bufStart, frames * 2);

  // Create AudioContext (lazy, requires user gesture)
  let ctx = null;
  let audioBuffer = null;

  function ensureContext() {
    if (ctx) return;
    ctx = new AudioContext({ sampleRate });
    audioBuffer = ctx.createBuffer(2, frames, sampleRate);
    deinterleaveStereo(audioBuffer, samples, frames, isInt16);
  }

  let source = null;
  let startedAt = 0;
  let pauseOffset = 0;
  let playing = false;
  const duration = frames / sampleRate;

  const player = {
    duration,

    get playing() { return playing; },

    get currentTime() {
      if (!playing || !ctx) return pauseOffset;
      return ctx.currentTime - startedAt;
    },

    play(offset) {
      if (playing) return;
      ensureContext();
      if (ctx.state === "suspended") ctx.resume();

      const from = offset ?? pauseOffset;
      source = ctx.createBufferSource();
      source.buffer = audioBuffer;
      source.connect(ctx.destination);
      startedAt = ctx.currentTime - from;
      source.start(0, from);
      playing = true;

      source.onended = () => {
        if (playing) {
          playing = false;
          pauseOffset = 0;
        }
      };
    },

    pause() {
      if (!playing || !source) return;
      pauseOffset = ctx.currentTime - startedAt;
      source.stop();
      source = null;
      playing = false;
    },

    stop() {
      if (source) {
        try { source.stop(); } catch (_) {}
        source = null;
      }
      pauseOffset = 0;
      playing = false;
    },

    seek(time) {
      const wasPlaying = playing;
      if (playing && source) {
        try { source.stop(); } catch (_) {}
        source = null;
        playing = false;
      }
      pauseOffset = Math.max(0, Math.min(time, duration));
      if (wasPlaying) player.play(pauseOffset);
    },

    destroy() {
      if (source) try { source.stop(); } catch (_) {}
      if (ctx) ctx.close();
      ctx = null;
      source = null;
    },
  };
  return player;
}
