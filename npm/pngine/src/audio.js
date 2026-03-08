// Sointu audio WASM player
// Instantiates a sointu-compiled WASM module, pre-renders audio,
// and provides synchronized playback via Web Audio API.

/**
 * Create an audio player from a sointu-compiled WASM module.
 *
 * Sointu WASM modules render the entire song during instantiation.
 * After instantiation, audio samples are available in WASM memory.
 * We copy them to an AudioBuffer for playback via Web Audio API.
 *
 * @param {Uint8Array} wasmBytes - Compiled sointu .wasm module
 * @returns {Promise<AudioPlayer>}
 */
export async function createAudioPlayer(wasmBytes) {
  // Instantiate sointu WASM (renders entire song during instantiation)
  const { instance } = await WebAssembly.instantiate(wasmBytes, { m: Math });

  // Read audio parameters from sointu exports
  const mem = instance.exports.m;
  const bufStart = instance.exports.s.value;
  const bufLen = instance.exports.l.value;
  const isInt16 = instance.exports.t.value === 1;

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

    // Deinterleave stereo samples into AudioBuffer channels
    for (let ch = 0; ch < 2; ch++) {
      const data = audioBuffer.getChannelData(ch);
      for (let i = 0; i < frames; i++) {
        data[i] = isInt16
          ? samples[i * 2 + ch] / 32768
          : samples[i * 2 + ch];
      }
    }
  }

  let source = null;
  let startedAt = 0;
  let pauseOffset = 0;
  let playing = false;
  const duration = frames / sampleRate;

  return {
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
      if (wasPlaying) this.play(pauseOffset);
    },

    destroy() {
      if (source) try { source.stop(); } catch (_) {}
      if (ctx) ctx.close();
      ctx = null;
      source = null;
    },
  };
}
