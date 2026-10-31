// Canonical default profile: lean production viewer.
export * from "./viewer.js";
// The payload walker over both carrier generations (02.C2): 03's core
// consumes only this on the JS side.
export { payloadsOf } from "./payloads.js";
// The FLAC twin (02.C3), a sibling rather than a format dispatcher inside
// payloadsOf: payloadsOf's non-PNG refusal is a pinned public contract, so
// 03's core dispatches on the format and reaches the FLAC walk here.
export { payloadsOfFlac } from "./flac-blocks.js";
