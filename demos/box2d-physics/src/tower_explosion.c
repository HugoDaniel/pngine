// Box2D v3 WASM Demo — Stacked Tower with Explosion
//
// A tall tower of 60 stacked boxes.
// After 2 seconds of settling, trigger b2World_Explode()
// to blow the tower apart dramatically.
//
// The explosion is triggered automatically via a frame counter,
// or manually by calling physics_explode() from the host.
//
// Compile: see README.md

#define CUSTOM_PHYSICS_STEP
#include "physics_common.h"

#define TOWER_COLS 4
#define TOWER_ROWS 15
#define BOX_SIZE 0.45f // half-extents
#define BOX_GAP 0.05f

static int g_frame_count = 0;
static bool g_exploded = false;

static void setup_scene(void) {
  // Ground
  add_static_segment(-15.0f, 0.0f, 15.0f, 0.0f);

  // Build tower: rows × cols of boxes
  float box_full = BOX_SIZE * 2.0f + BOX_GAP;
  float base_x = -(float)(TOWER_COLS - 1) * box_full * 0.5f;

  for (int row = 0; row < TOWER_ROWS; row++) {
    for (int col = 0; col < TOWER_COLS; col++) {
      float x = base_x + (float)col * box_full;
      float y = BOX_SIZE + (float)row * (BOX_SIZE * 2.0f + BOX_GAP);

      // Offset odd rows for a brick pattern
      if (row % 2 == 1) {
        x += box_full * 0.5f;
      }

      add_dynamic_box(x, y, BOX_SIZE, BOX_SIZE);
    }
  }
}

// Override physics_step to auto-explode after settling
__attribute__((export_name("physics_step"))) void physics_step(float dt) {
  if (!g_initialized)
    physics_init();
  b2World_Step(g_world, dt, 4);

  g_frame_count++;

  // Auto-explode after ~120 frames (2 seconds at 60fps)
  if (g_frame_count == 120 && !g_exploded) {
    g_exploded = true;
    physics_explode(0.0f, 2.0f, 8.0f, 50.0f);
  }
}
