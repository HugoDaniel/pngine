// The light list, as the compute pass that moves the lights and the lighting
// pass that reads them both have to lay it out. Two structs, no bindings: the
// compute root binds this array `read_write` and the lighting root binds it
// `read`, which is a difference the roots own and this file does not mention.
//
// 32 bytes per light, which is what `(buffer :size (* NUM_LIGHTS 32))` counts.

struct Light {
  position: vec3f,
  radius: f32,
  color: vec3f,
  pad: f32,
}

struct Lights {
  l: array<Light>,
}
