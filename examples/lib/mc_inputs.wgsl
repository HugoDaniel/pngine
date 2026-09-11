// The 16-byte `pngine-inputs` uniform, as every root that reads the clock
// lays it out. A struct, not a binding: each root declares its own
// `var<uniform>` at whatever group and binding its pipeline puts it.

struct PngineInputs { time: f32, width: f32, height: f32, aspect: f32 }
