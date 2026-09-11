// The camera block the camera compute pass writes and the two render roots
// read. It is its own file rather than part of ./mc_inputs.wgsl because a root
// that imports a fragment carries every declaration in it: the render roots
// never look at the clock, and the camera root writes this and reads that.

struct MVPData { matrix: mat4x4f, camPos: vec4f }
