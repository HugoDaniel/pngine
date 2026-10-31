# IANA filing: the FLAC Application Metadata Block ID `pNGx`

**2026-10-05, the owner's decision: this filing is not being submitted.** The `pNGx`
application ID stays a **family convention**, on the same level as `pNGx` the PNG chunk
type: four bytes the family agrees on, with no registration body involved on either side
(02's `pNGx` public-bit risk). The IANA work is deferred "for the time being", in the owner's words, not
foreclosed and not rejected: the ID remains unclaimed (the registry holds 24 IDs, none
beginning with `pNG`), and this document is kept intact below as the draft a future
decision would resume from. Nothing below this note is an action anyone owes: the
"PENDING SUBMISSION" status is held, the "TODO-for-submitter" fields wait on a future
submitter who may never be asked, and "After submission" describes only what a resumption
would do. The code needs no change either way; readers treat an unregistered and a
registered ID identically, opaque and skipped.

Status: **PREPARED 2026-10-05, PENDING SUBMISSION.** This document is the
text a human submits to IANA; pngine's agents do not send filings, and
nothing has been registered. Until the registration lands, the ID is merely
unregistered, which decoders treat like any APPLICATION block: opaque,
skipped (the spec's own words, 02:126-127).

Registry: **FLAC Application Metadata Block IDs** (RFC 9639 section 8.4),
First Come First Served. Filed through IANA's protocol-assignment form
("Application ID" under the FLAC registries).

## The form fields

| Field | Value |
| --- | --- |
| Application ID | `0x704E4778` (`pNGx`) |
| Application name | PNGine payload envelope (PNGine) |
| Contact name | Hugo Daniel (the repository owner, npm/pngine/package.json's author field) |
| Contact email | TODO-for-submitter: the maintainer's real address; an agent must not invent one |
| Spec URL | https://github.com/HugoDaniel/pngine/blob/main/docs/payload-kinds.md |
| Reference | RFC 9639 (the registry's defining document, section 8.4) |

## Why these values

- The ID `pNGx` = 0x704E4778 is "the same four bytes as the PNG chunk type,
  so one constant marks the envelope in both containers and `pngine ls`
  needs no per-container vocabulary" (02:121-122). RFC 9639 section 8.4
  stores IDs big-endian, exactly as the four ASCII bytes read; the constant
  lives in `src/flac/blocks.zig` (`APP_ID`).
- The application name says what the block is, not only whose it is: the
  block carries pngine's carrier-agnostic payload envelope
  (`docs/payload-kinds.md`), one payload per block, any kind.
- The spec URL points at `docs/payload-kinds.md`, the document the
  checkpoint names as the spec ("a spec URL - docs/payload-kinds.md",
  02:124-126): the envelope layout, the case rule, and the registry the
  filing backs. TODO-for-submitter: confirm the canonical public URL and
  branch at submission time (main today; a tag or a docs site would serve
  better if one exists by then).
- The contact is the repository owner because registration questions route
  to whoever can change the writer, not to whoever filed.

## What the ID must never become

The registry entry claims four bytes in FLAC metadata blocks, nothing else:
no codec behaviour, no framing change, no claim on PNG chunk types (those
are PNG's own ancillary namespace, and `pNGx` there is pngine's family
convention, 02:204-206). The 24 IDs IANA had when the spec was written
include none beginning with `pNG` (02:123-124).

## After submission

Record the registration date here and in the expansible-player spec's FLAC
section (its checkpoint 02.C3 line "IANA registration filed (dated here)");
this document then becomes the receipt. The code needs no change: readers
already treat an unregistered and a registered ID identically, which is the
point of filing rather than hacking.
