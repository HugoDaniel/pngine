// Live-resource accounting for a command dispatcher.
//
// The instrument a long-running session needs: exact counts of the GPU objects
// the runtime is holding right now, independent of logs, DEBUG defines and GC
// timing. Heap size cannot answer "did 600 frames strand anything" — a GPU
// object is a few bytes of JS wrapper over driver memory the heap never sees —
// and forcing GC before every sample only tells you what was collectable, not
// what the runtime still believes it owns.
//
// Counts are DERIVED from the resource tables rather than accumulated at each
// create site. That is deliberate: a create site the instrumentation missed
// would report a leak as zero, which is the one failure mode a leak instrument
// must not have. Walking the tables cannot miss a resource that is in a table,
// and a resource that is in no table is not retained by the dispatcher at all.
//
// Cost is O(total ids) per call, and it is called per stats request — never per
// frame.

/**
 * Populated slots per table. The tables are sparse arrays indexed by resource
 * id, so holes read as undefined and are skipped.
 *
 * @param {Record<string, ArrayLike<unknown>>} tables
 * @returns {{live: Record<string, number>, total: number}}
 */
export function countLive(tables) {
  /** @type {Record<string, number>} */
  const live = {};
  let total = 0;
  for (const kind in tables) {
    const table = tables[kind];
    let n = 0;
    for (let i = 0; i < table.length; i++) if (table[i]) n++;
    live[kind] = n;
    total += n;
  }
  return { live, total };
}

/**
 * GPUBindGroups alive beyond the ones in `bg`: set_bind_group caches a rebuilt
 * group per (bind group, pipeline) when a group is bound under a pipeline other
 * than the one whose auto-layout produced it. Those are real, retained
 * GPUBindGroups that appear in no table — the exact shape of the leak that made
 * this instrument worth having (register A1) — so a count that ignored them
 * would report flat while the runtime grew.
 *
 * @param {ArrayLike<{alt?: Map<number, unknown>|null}>} bgd
 */
export function countCachedBindGroups(bgd) {
  let n = 0;
  for (let i = 0; i < bgd.length; i++) {
    const alt = bgd[i]?.alt;
    if (alt) n += alt.size;
  }
  return n;
}
