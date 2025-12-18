// Cat SDF Texture Baking Shader
// Bakes 6 cat shapes into a 3x2 grid texture atlas
// Each tile stores the signed distance field for one cat shape

struct VSOutput {
  @builtin(position) position: vec4f,
  @location(0) texcoord: vec2f,
};

@vertex fn vs_catSdfTexture(@builtin(vertex_index) vertexIndex : u32) -> VSOutput {
  var pos = array(
    vec2f(-1.0, -1.0),
    vec2f(-1.0,  3.0),
    vec2f( 3.0, -1.0),
  );

  var vsOutput: VSOutput;
  let xy = pos[vertexIndex];
  vsOutput.position = vec4f(xy, 0.0, 1.0);
  vsOutput.texcoord = xy * vec2f(0.5, -0.5) + vec2f(0.5);
  return vsOutput;
}

// Grid layout: 3 columns x 2 rows = 6 cats
const COLS: f32 = 3.0;
const ROWS: f32 = 2.0;

// SDF encoding: map [-maxDist, +maxDist] to [0, 1]
// 0.5 = on the surface, < 0.5 = inside, > 0.5 = outside
const MAX_DIST: f32 = 3.0;

// Tangram coordinate range - cats extend from about -2.5 to +2.5
const TANGRAM_RANGE: f32 = 6.0;  // Total range: [-3, 3]

fn encode_sdf(dist: f32) -> f32 {
    return clamp(dist / MAX_DIST * 0.5 + 0.5, 0.0, 1.0);
}

// Compute SDF for a specific cat shape
fn cat_sdf(local_uv: vec2f, cat_index: u32) -> f32 {
    // Map UV from [0,1] to centered coordinates for tangram space
    let p = (local_uv - 0.5) * TANGRAM_RANGE;

    var min_dist: f32 = 1e10;

    // Get transforms for this cat shape
    for (var i = 0u; i < 7u; i++) {
        var transform: Transform2D;

        switch cat_index {
            case 0u: { transform = state_cat1[i]; }
            case 1u: { transform = state_cat2[i]; }
            case 2u: { transform = state_cat3[i]; }
            case 3u: { transform = state_cat4[i]; }
            case 4u: { transform = state_cat5[i]; }
            default: { transform = state_cat6[i]; }
        }

        let piece_dist = tangramPieceSDF(p, pieces[i], transform);
        min_dist = min(min_dist, piece_dist);
    }

    return min_dist;
}

@fragment fn fs_catSdfTexture(fsInput: VSOutput) -> @location(0) vec4f {
    let uv = fsInput.texcoord;

    // Determine which tile we're in (3x2 grid)
    let tile_x = floor(uv.x * COLS);
    let tile_y = floor(uv.y * ROWS);
    let cat_index = u32(tile_y * COLS + tile_x);

    // Get local UV within tile [0, 1]
    let local_uv = vec2f(
        fract(uv.x * COLS),
        fract(uv.y * ROWS)
    );

    // Compute SDF for this cat
    let dist = cat_sdf(local_uv, cat_index);

    // Encode SDF to color
    let encoded = encode_sdf(dist);

    // Store in R channel, use G for additional precision if needed
    // For now, just R channel with encoded distance
    return vec4f(encoded, encoded, encoded, 1.0);
}
