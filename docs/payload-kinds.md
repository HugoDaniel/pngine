# Payload kinds

Status: **FROZEN v1 at X0** (2026-10-05, checkpoint 02.C1). The envelope and
this registry froze together: P61 is both. Layout and rules live in the
expansible-player plan set, `docs/02-envelope-and-containers.md` at
`a7220d5`; line citations below ("02:NN") point into that file. This
document is pngine's materialization of the registry, held against
`src/payload/envelope.zig`'s `v1_kinds` table by
`zig build drift_payload_kinds`.

## The envelope, in brief

Eight bytes, then the body (02:12-26):

| Position | Field | Rule |
| --- | --- | --- |
| 0..4 | `kind` | four printable ASCII bytes, the tag below |
| 4 | `version` | the KIND's format version; checked by the handler, never by the walker (02:16, 02:36-39) |
| 5 | `flags` | bit0 raw DEFLATE (0x01, exactly pngine's `FLAG_COMPRESSED`), bit1 continued; bits 2-7 reserved, must be zero (02:17-23) |
| 6..8 | `reserved` | u16, zero; capacity to grow into in place, never a slot to reorder around (02:24-25) |

A reader that meets a reserved flag bit (or a nonzero reserved u16, a record
shorter than the header, a kind it has no handler for, or a `continued` chain
no further envelope completes) skips the payload and lists it; it never
guesses and never refuses the whole file (02:22-23). `continued`
concatenates in container order, per kind; writers split only where the
carrier forces it (02:19-21).

## Case rule

Uppercase-initial tags are REGISTERED in this document, drift-checked
against `src/payload/envelope.zig` (02:31-34). Lowercase-initial tags are
private/experimental: never registered, never claimed by the family, and
never listed here. A reader parses them like any other envelope.

## The v1 inventory

Registered means the owner's compiler exists in the family and a demo
landed in 07. Reserved means the row claims its four bytes with kind, body,
owner and legacy carrier while that compiler is pending: the `ZFTB`
precedent, made a rule by the 2026-10-04 note below (02:64-73).

| Tag | Status | Owner | Handler | Legacy carrier | Body | Provenance |
| --- | --- | --- | --- | --- | --- | --- |
| `PNGB` | registered | pngine | `webgpu-exec` (03) | `pNGb` | PNGB bytecode with the executor nested inside, v1 | 02:45 |
| `PNGF` | registered | pngine | `webgpu-flat` (03) | `pNGf` | flat command stream, v2 | 02:46 |
| `WGSL` | registered | pngine | none (tooling) | `pNGw` (reserved, never written) | DEFLATE'd WGSL source | 02:47 |
| `META` | registered | pngine | `meta` (03) | `pNGm` (reserved, `versioned_raw`, no flags byte; the one irregular legacy header) | JSON: `title, author, url, license, created, clock, audio` | 02:48 |
| `SNTU` | registered | Sointu | `sointu` (03) | `pNGa` (version written, never checked) | a compiled Sointu song: a wasm module instantiated with `{m: Math}` exporting `m/s/l/t` | 02:49 |
| `AZBC` | registered | audzio | `audzio` (03) | none | audzio bytecode with its executor nested | 02:50 |
| `AZFL` | registered | audzio | `audzio-mini` (03) | none | audzio flat command stream | 02:51 |
| `AZSR` | registered | audzio | none (tooling: `extract --kind AZSR`) | none | the `(audio-graph ...)` source of the `AZBC`/`AZFL` in the same file, DEFLATE'd SJON text; what an editor round-trips | 02:52 |
| `ITMD` | registered | batida | `it-module` (future) | none | an Impulse Tracker module's bytes for batida's wasm player | 02:53 |
| `PACR` | registered | pacer | `score` (05) | none | a pacer score document (SJON text) | 02:54 |
| `PACB` | reserved | pacer | none (pacer's own runtime loads it) | none | a compiled pacer cartridge (`'PACB'` container, opaque binary; pacer owns the format) | dated note 2026-10-20 below |
| `ZFTB` | reserved | canto | `font` (future) | none | one baked slug font: `curves ‖ bands ‖ meta` (ZFT1) behind a 12 B sub-header of three `u32` lengths; reserved 2026-08-28 by the font-api set | 02:55 |
| `ENCA` | registered | anyone | `enca` (03; audio only, clock-capable) | none | an encoded audio file (FLAC/WAV/OGG/MP3 bytes) decoded by the browser's `decodeAudioData` | 02:56 |
| `PNGI` | registered | anyone | none (walker) | none | a whole PNG; its payloads are walked at depth 1 | 02:57 |
| `ANPC` | reserved | animader | none (tooling; the piece plays through its compiled `PNGB`/`PNGF`) | none | a piece's aggregate SJON text, the one-file export's first payload; body details fixed in the kind contract at registration | 02:58 |
| `ANLG` | reserved | animader | none (tooling: `extract --kind ANLG`) | none | a session document: SJON text per animader's `docs/session-format.md` today; a binary body (`'ANEV'` the candidate) and its representation discriminator are the kind contract's to fix at registration | 02:59 |

Handlers shipped at X1: `PNGB`, `PNGF`, `SNTU`, `META` (02:61-62). The rest
arrive with their owners; the tags are reserved now so no two sets pick the
same four bytes (02:59-60).

## Dated notes

**2026-10-04.** The registry is two-step, as the `ZFTB` row already practiced
and ask 01 (`plans/asks/01-anlg-anpc-payload-kinds.md` in the same set) made
explicit. *Reservation*: an owner in the family claims four bytes the day it
asks; the row carries kind, body, owner and legacy carrier, and nothing else
is owed. *Registration*: when the owner's compiler exists in the family and
a demo lands in 07, the body contract is written into this document and a
handler row joins 03 if one is owed. The registry froze with 02.C1 at X0,
together with the envelope. After the freeze a reservation is an appended
dated note here plus its row in this document with `drift_payload_kinds`
green, never a silent row. `ANLG` and `ANPC` (animader, 2026-10-04) are
reserved, not registered. (02:64-73, ask 01 verdict sections 1-3.)

**2026-10-05.** FREEZE v1. `src/payload/envelope.zig` and
`npm/pngine/src/envelope.js` land the frozen readers with byte goldens
authored from the spec; this document lands the inventory. After the freeze,
reserved bytes and flag bits are spare capacity to grow into in place,
never slots to reorder around (02:24-25, the PNGB header's discipline).

**2026-10-20.** pacer reserves `PACB`: a compiled pacer cartridge (the
`'PACB'` container its `pacer pack` verb writes) — an opaque binary whose
format pacer owns; owner pacer, no handler, no legacy carrier. Reserved,
not registered: pngine neither parses nor dispatches the body, and nothing
autoplay-claims it — consumers extract the stored bytes through
`payloadsOf` and hand them to pacer's own runtime. The registered `PACR`
row (score text) is untouched by this reservation.

## Drift

`zig build drift_payload_kinds` (`scripts/check-payload-kinds.mjs`) compares
this document's inventory table against `src/payload/envelope.zig`'s
`v1_kinds`: the tag SET must match exactly on both sides, and each row's
Status and Owner must agree. A lowercase-initial tag in the table is a
failure (private tags are never listed). Bodies, handlers and legacy
carriers are prose this document carries alone: the reservation rule owes
kind, body, owner and legacy carrier, and the gate pins the three
machine-checkable of the four; the fourth is the row's prose.
