// Box2D v3 WASM Demo — Circle Avalanche
//
// Circles pour down from above onto angled ramps and obstacles,
// creating a particle-system-like avalanche effect.
// New circles are spawned over time for a continuous flow.
//
// Compile: see README.md

#define CUSTOM_PHYSICS_STEP
#include "physics_common.h"

#define INITIAL_CIRCLES 40
#define CIRCLE_RADIUS 0.25f
#define SPAWN_INTERVAL 5 // spawn new circle every N frames
#define MAX_SPAWN 200    // stop spawning after this many

static int g_frame_count = 0;
static int g_spawned = 0;

// Simple pseudo-random for spawn positions (no stdlib needed in WASM)
static unsigned int g_seed = 12345;
static float rand_float(float lo, float hi) {
  g_seed = g_seed * 1103515245 + 12345;
  float t = (float)((g_seed >> 16) & 0x7FFF) / 32767.0f;
  return lo + t * (hi - lo);
}

static void setup_scene(void) {
  // Funnel walls (V-shape at top)
  add_static_segment(-8.0f, 20.0f, -2.0f, 14.0f); // left wall of funnel
  add_static_segment(8.0f, 20.0f, 2.0f, 14.0f);   // right wall of funnel

  // Zigzag ramps
  add_static_segment(-6.0f, 10.0f, 2.0f, 8.0f); // ramp 1 (left to right)
  add_static_segment(6.0f, 6.0f, -2.0f, 4.0f);  // ramp 2 (right to left)
  add_static_segment(-6.0f, 2.0f, 2.0f, 0.5f);  // ramp 3

  // Collection basin at bottom
  add_static_segment(-10.0f, -2.0f, -7.0f, 0.0f); // left basin wall
  add_static_segment(10.0f, -2.0f, 7.0f, 0.0f);   // right basin wall
  add_static_segment(-7.0f, 0.0f, 7.0f, 0.0f);    // basin floor

  // Static obstacle pegs
  add_static_box(-1.0f, 12.0f, 0.3f, 0.3f);
  add_static_box(1.0f, 12.0f, 0.3f, 0.3f);
  add_static_box(0.0f, 9.0f, 0.3f, 0.3f);
  add_static_box(-3.0f, 5.0f, 0.3f, 0.3f);
  add_static_box(3.0f, 5.0f, 0.3f, 0.3f);

  // Initial batch of circles at the top
  for (int i = 0; i < INITIAL_CIRCLES; i++) {
    float x = rand_float(-1.5f, 1.5f);
    float y = 16.0f + rand_float(0.0f, 6.0f);
    add_dynamic_circle(x, y, CIRCLE_RADIUS);
    g_spawned++;
  }
}

// Override physics_step to spawn circles over time
__attribute__((export_name("physics_step"))) void physics_step(float dt) {
  if (!g_initialized)
    physics_init();
  b2World_Step(g_world, dt, 4);

  g_frame_count++;

  // Continuously spawn new circles
  if (g_frame_count % SPAWN_INTERVAL == 0 && g_spawned < MAX_SPAWN &&
      g_body_count < MAX_BODIES) {
    float x = rand_float(-1.5f, 1.5f);
    float y = 18.0f + rand_float(0.0f, 2.0f);
    add_dynamic_circle(x, y, CIRCLE_RADIUS);
    g_spawned++;
  }
}
