// The surface normal, as a central difference of the scalar field. Two holes:
// `field`, which each document supplies as its own instance fragment, and
// `pngine`, the uniform whichever root imports this declares.
//
// It is a file of its own for the reason the plan calls the cost of coarse
// fragments: the INDEX generator reads the same density grid and never
// computes a normal, so if this function sat in ./mc_grid.wgsl the index root
// would have to import a field instance to satisfy a call it never makes.
//
// The field is positive inside, so its gradient points inward and the outward
// normal is the NEGATED central difference. A signed distance function is the
// same expression with the operands the other way round, which is why the
// marching-cubes instance defines `field` as `-sdf` and this stays one
// function for both documents.

fn computeNormal(pos: vec3f) -> vec3f {
  let eps = 0.5;
  let t = pngine.time;
  return normalize(vec3f(
    field(pos - vec3f(eps, 0, 0), t) - field(pos + vec3f(eps, 0, 0), t),
    field(pos - vec3f(0, eps, 0), t) - field(pos + vec3f(0, eps, 0), t),
    field(pos - vec3f(0, 0, eps), t) - field(pos + vec3f(0, 0, eps), t)
  ));
}
