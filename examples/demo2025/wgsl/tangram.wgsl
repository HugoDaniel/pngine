const square_col = vec3<f32>(0.773, 0.561, 0.702);
const bigtri1_col = vec3<f32>(0.502, 0.749, 0.239);
const bigtri2_col = vec3<f32>(0.494, 0.325, 0.545);
const midtri_col = vec3<f32>(0.439, 0.573, 0.235);
const smalltri1_col = vec3<f32>(0.604, 0.137, 0.443);
const smalltri2_col = vec3<f32>(0.012, 0.522, 0.298);
const parallelogram_col = vec3<f32>(0.133, 0.655, 0.420);

struct TangramPiece {
    type_id: u32,  // 0: big tri, 1: medium tri, 2: small tri, 3: square, 4: parallelogram
    color: vec3f,
    transform: Transform2D,
}

const pieces: array<TangramPiece, 7> = array(
    TangramPiece(0u, square_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(1u, bigtri1_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(2u, bigtri2_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(3u, midtri_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(4u, smalltri1_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(5u, smalltri2_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(6u, parallelogram_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
);

const state_closed: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const NO_SCALE = vec2f(1.0);
const NO_ANCHOR = vec2f();

const opened1: array<vec3f, 7> = array(
    vec3f(-0.25, 0.0, -PI * 0.25), // (x, y, rot)
    vec3f(0.0, 0.8, -0.18), // (x, y, rot)
    vec3f(-0.8, 0.3, -0.18),
    vec3f(0.6, -0.6, 0.33),
    vec3f(0.5, 0.2, 0.1),
    vec3f(-0.83, -0.2, -0.22),
    vec3f(-0.6, -0.5, 0.15)
);
const opened2: array<vec3f, 7> = array(
vec3f(0.8299, -0.2971, -0.6524),
vec3f(0.0603, -0.2038, -0.3624),
vec3f(-0.2295, 0.3802, -0.7075),
vec3f(-0.8291, -0.1798, -0.2569),
vec3f(-0.5892, -0.4718, 0.0468),
vec3f(-0.1378, -0.9420, 0.9490),
vec3f(0.2372, -0.8925, -0.5848)
);
const opened3: array<vec3f, 7> = array(
vec3f(0.5866, -0.0731, 0.3487),
vec3f(0.2497, 0.0812, 0.5356),
vec3f(-0.9578, 0.5864, -0.9372),
vec3f(0.2719, -0.8279, -0.2967),
vec3f(0.9875, 0.6842, -0.8199),
vec3f(0.0591, 0.1690, 0.7445),
vec3f(0.8652, 0.7285, 0.9075)
);
const opened4: array<vec3f, 7> = array(
vec3f(0.7298, -0.1844, -0.8829),
vec3f(-0.6386, 0.2373, 0.6857),
vec3f(0.4874, 0.6762, -0.2665),
vec3f(0.0187, 0.7647, 0.7766),
vec3f(-0.0020, 0.4670, 0.5772),
vec3f(0.4625, 0.9333, 0.4251),
vec3f(-0.5837, -0.3241, -0.4141)
);
const opened5: array<vec3f, 7> = array(
vec3f(0.4641, -0.9143, -0.5553),
vec3f(0.3456, 0.3496, 0.6253),
vec3f(-0.1729, -0.9265, 0.5243),
vec3f(-0.9456, 0.2857, 0.9052),
vec3f(-0.4753, -0.9353, -0.4513),
vec3f(-0.6442, -0.0122, 0.4895),
vec3f(-0.2449, 0.7356, -0.5364),
);
const opened6: array<vec3f, 7> = array(
vec3f(-0.5494, 0.1209, -0.3446),
vec3f(0.6194, 0.1650, -0.3516),
vec3f(0.3084, -0.9546, 0.6568),
vec3f(0.6092, -0.7844, 0.4603),
vec3f(-0.2424, 0.5443, 0.3551),
vec3f(0.0452, 0.9335, 0.1202),
vec3f(-0.9766, 0.9581, 0.9510)
);
const opened7: array<vec3f, 7> = array(
vec3f(0.9790, -0.5485, 0.6795),
vec3f(-0.0338, -0.6303, 0.5231),
vec3f(-0.8277, 0.0536, -0.6659),
vec3f(-0.1872, 0.1918, -0.3223),
vec3f(0.8099, -0.7996, 0.6587),
vec3f(0.5825, -0.7581, -0.3017),
vec3f(-0.3753, -0.5009, -0.4534)
);


const state_opened1: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened1[0].xy, 2.0 * PI * opened1[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[1].xy, 2.0 * PI * opened1[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[2].xy, 2.0 * PI * opened1[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[3].xy, 2.0 * PI * opened1[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[4].xy, 2.0 * PI * opened1[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[5].xy, 2.0 * PI * opened1[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[6].xy, 2.0 * PI * opened1[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened2: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened2[0].xy, 2.0 * PI * opened2[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[1].xy, 2.0 * PI * opened2[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[2].xy, 2.0 * PI * opened2[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[3].xy, 2.0 * PI * opened2[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[4].xy, 2.0 * PI * opened2[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[5].xy, 2.0 * PI * opened2[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[6].xy, 2.0 * PI * opened2[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened3: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened3[0].xy, 2.0 * PI * opened3[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[1].xy, 2.0 * PI * opened3[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[2].xy, 2.0 * PI * opened3[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[3].xy, 2.0 * PI * opened3[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[4].xy, 2.0 * PI * opened3[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[5].xy, 2.0 * PI * opened3[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[6].xy, 2.0 * PI * opened3[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened4: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened4[0].xy, 2.0 * PI * opened4[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[1].xy, 2.0 * PI * opened4[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[2].xy, 2.0 * PI * opened4[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[3].xy, 2.0 * PI * opened4[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[4].xy, 2.0 * PI * opened4[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[5].xy, 2.0 * PI * opened4[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[6].xy, 2.0 * PI * opened4[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened5: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened5[0].xy, 2.0 * PI * opened5[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[1].xy, 2.0 * PI * opened5[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[2].xy, 2.0 * PI * opened5[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[3].xy, 2.0 * PI * opened5[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[4].xy, 2.0 * PI * opened5[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[5].xy, 2.0 * PI * opened5[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[6].xy, 2.0 * PI * opened5[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened6: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened6[0].xy, 2.0 * PI * opened6[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[1].xy, 2.0 * PI * opened6[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[2].xy, 2.0 * PI * opened6[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[3].xy, 2.0 * PI * opened6[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[4].xy, 2.0 * PI * opened6[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[5].xy, 2.0 * PI * opened6[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[6].xy, 2.0 * PI * opened6[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened7: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened7[0].xy, 2.0 * PI * opened7[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[1].xy, 2.0 * PI * opened7[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[2].xy, 2.0 * PI * opened7[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[3].xy, 2.0 * PI * opened7[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[4].xy, 2.0 * PI * opened7[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[5].xy, 2.0 * PI * opened7[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[6].xy, 2.0 * PI * opened7[6].z, NO_SCALE, NO_ANCHOR),
);



const state_cat1: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(0.7, 0.79), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.5, 0.0), -PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.5, -1.41), PI * 1.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.21, 0.29), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.7, 1.79), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.20, 1.29), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.0, -0.91), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat2: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(0.9, -0.21), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.8, -0.5), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -0.21), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.095, 0.205), PI * 1.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -0.21), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.40, 0.29), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.8, -0.5), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat3: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-0.1, 0.91), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.51, -0.5), -PI * 0.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -0.5), PI * 1.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -1.9), PI*1.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, 1.91), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.4, 1.41), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.19, -0.5), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat4: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-1.02, 0.5), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.515, 0.0), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, 0.0), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.19, -0.71), PI*0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.02, 0.5), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.52, 1.0), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.61, -1.42), PI * 0.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat5: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-1.0, -0.25), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( 0.91, -0.75), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.61, -1.458), -PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.2, -0.04), PI*0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.0, -0.25), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.5, 0.25), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.2, -0.46), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);
const state_cat6: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(1.3, -0.86), PI * 0.666, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( 0.91, -0.75), PI * 0.666, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.675, -1.085), -PI * 1.085, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.515, -0.65), PI*1.416, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.61, -0.67), PI * 0.16, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.8, 0.005), PI * 1.666, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-2.49, 0.05), PI * 0.45, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_heart: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-0.5, -1.00), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( 0.5, -1.00), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.5, 1.0), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.5, -1.0), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 1.5), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, -0.5), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.0, -0.5), PI, vec2<f32>(-1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const tangram_drawings: array<array<Transform2D, 7>, 7> = array(
    state_cat1,
    state_cat2,
    state_cat3,
    state_cat4,
    state_cat5,
    state_cat6,
    state_heart,
);
const tangram_openings: array<array<Transform2D, 7>, 7> = array(
    state_opened1,
    state_opened2,
    state_opened3,
    state_opened4,
    state_opened5,
    state_opened6,
    state_opened7,
);

// ---- Tangram Piece SDFs ----
// (These define the shapes in their local unit space)

fn tangramBigTri1(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(-1.0, 1.0),
        vec2(0.0, 0.0),
        vec2(1.0, 1.0)
    ), transform);
}
fn tangramBigTri2(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(-1.0, 1.0),
        vec2(0.0, 0.0),
        vec2(-1.0, -1.0)
    ), transform);
}

fn tangramMidTri(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(1.0, -1.0),
        vec2(1.0, 0.0),
        vec2(0.0, -1.0)
    ), transform);
}
fn tangramSmallTri1(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(1.0, 1.0),
        vec2(1.0, 0.0),
        vec2(0.5, 0.5)
    ), transform);
}
fn tangramSmallTri2(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(0.0, 0.0),
        vec2(0.5, -0.5),
        vec2(-0.5, -0.5)
    ), transform);
}

fn tangramSquare(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    // NOTE: This is the hard-coded transform discussed in the previous answer.
    // For a more flexible system, this transform should be part of the `pieces` data.
    var sqTransform: Transform2D;
    sqTransform.pos = vec2f(0.501, 0.0);
    sqTransform.angle = PI * 0.25;
    sqTransform.scale = vec2f(1.0, 1.0);
    // The final distance is scaled by the main piece's transform
    return scale_sdf_distance(transformedBox(q, vec2<f32>(0.3535, 0.3535), sqTransform),
    transform);
}

fn tangramParallelogram(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    // NOTE: This is also a hard-coded local transform.
    var parallelogramTransform: Transform2D;
    parallelogramTransform.pos = vec2f(-0.25, -1.0 + 0.25);
    parallelogramTransform.scale = vec2f(1.0, 1.0);
    parallelogramTransform.angle = 0.0;
    parallelogramTransform.anchor = vec2f(0.0);

    return scale_sdf_distance(transformedParallelogram(q, 0.5, 0.25, 0.25, parallelogramTransform), transform);
}


fn tangramPieceSDF(p: vec2f, piece: TangramPiece, transform: Transform2D) -> f32 {
    switch piece.type_id {
        case 0u: { // Square
            return tangramSquare(p, transform);
        }
        case 1u: { // Big Triangle 1
            return tangramBigTri1(p, transform);
        }
        case 2u: { // Big triangle 2
            return tangramBigTri2(p, transform);
        }
        case 3u: { // Mid Triangle
            return tangramMidTri(p, transform);
        }
        case 4u: { // Small Triangle 1
            return tangramSmallTri1(p, transform);
        }
        case 5u: { // Small Triangle 2
            return tangramSmallTri2(p, transform);
        }
        case 6u: { // Parallelogram
            return tangramParallelogram(p, transform);
        }
        default: {
            return AWAY; // Large distance for invalid type
        }
    }
}

fn fullTangramSDF(uv: vec2f, transform: Transform2D, pieces_transform: array<Transform2D, 7>) -> f32 {
    let q = transform_to_local(uv, transform);
    var result: f32 = AWAY;

    // Smooth blending for seamless edges
    let k = 0.01;

    for (var i = 0u; i < 7u; i++) {
        // Get animated state for this specific piece
        let shape_positions = pieces_transform[i];

        let piece_dist = tangramPieceSDF(q, pieces[i], shape_positions);
        // NOTE: Removed double scale correction - tangramPieceSDF already applies it

        result = smin(result, piece_dist, k);
    }
    return result;
}

fn boxOfBoxesTransform(BOB_SIZE: f32) -> array<Transform2D, 9> {
  return array<Transform2D, 9>(
    // First row (top left first)
    Transform2D(vec2f(0.0, -BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(-BOB_SIZE, -BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(BOB_SIZE, -BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),

    // Middle row (left first)
    Transform2D(vec2f(-BOB_SIZE, 0.0), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(BOB_SIZE, 0.0), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),

    // Bottom row (right first)
    Transform2D(vec2f(BOB_SIZE, BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(0.0, BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(-BOB_SIZE, BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
  );
}

fn catFaceLogo2(p: vec2f, size: f32, whiskers_t:f32, transform: Transform2D) -> f32 {
  let qt = transform_to_local(p, transform);
  let catTransf = Transform2D(vec2f(), PI * 1.75, vec2f(1.0), vec2f());
  let q = transform_to_local(qt, catTransf);

  let bob_half_size = size / 3.0;
  let bob_size = bob_half_size * 2.0;

  let transforms = boxOfBoxesTransform(bob_size);
  var d = AWAY * 1000.0;
  for (var i = 0u; i < 8; i++) {
    let transf = transforms[i];

    d = min(d, transformedBox(q, vec2f(bob_half_size), transf)); //  - 0.001;
  }

  let cat = scale_sdf_distance(d, catTransf);

  let whiskersThickness = size * 0.0025;
  let startingY = -size * 0.8;
  let box1 = transformedBox(qt, vec2f(size * 0.8, whiskersThickness), Transform2D(vec2f(0.0, startingY), 0.0, vec2f(1.0), vec2f()));
  let box2 = transformedBox(qt, vec2f(size * 0.9, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness * 50.0), 0.0, vec2f(1.0), vec2f()));
  let box3 = transformedBox(qt, vec2f(size, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness * 100.0), 0.0, vec2f(1.0), vec2f()));

  return min(min(min(cat, box1), box2), box3);
}

const CAT: array<vec2f, 6> = array(
    vec2f(0, 212.13),
    vec2f(212.13, 424.26),    
    vec2f(424.26, 212.13),
    vec2f(282.84, 70.71),
    vec2f(212.13, 141.42),
    vec2f(141.42, 70.71)
);
fn catFaceLogo(p: vec2f, p_size: f32, whiskers_t:f32, transform: Transform2D) -> f32 {
  let qt = transform_to_local(p, transform);
  let size = 1.0 / 300.0;
  let catTransf = Transform2D(vec2f(0.71), PI, vec2f(size), vec2f());
  let q = transform_to_local(qt, catTransf);

  let polyCat = sixPolygon(q, CAT);
  let cat = scale_sdf_distance(polyCat, catTransf);

  let whiskersThickness = 0.02;
  let whiskersSize = 0.45; // 0.4;
  let whiskersMargin = 0.06;
  let startingY = -0.45;
  let box1 = transformedBox(qt, vec2f(whiskersSize * 0.8, whiskersThickness), Transform2D(vec2f(0.0, startingY), 0.0, vec2f(1.0), vec2f()));
  let box2 = transformedBox(qt, vec2f(whiskersSize * 0.9, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness + whiskersMargin * 0.828), 0.0, vec2f(1.0), vec2f()));
  let box3 = transformedBox(qt, vec2f(whiskersSize, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness + whiskersMargin * 2.0), 0.0, vec2f(1.0), vec2f()));
  let box1_scaled = scale_sdf_distance(box1, catTransf);
  let box2_scaled = scale_sdf_distance(box2, catTransf);
  let box3_scaled = scale_sdf_distance(box3, catTransf);

  return min(min(min(cat, box1_scaled), box2_scaled), box3_scaled);
}


