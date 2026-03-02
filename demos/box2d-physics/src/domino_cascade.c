// Box2D v3 WASM Demo — Domino Cascade
//
// ~30 tall, thin domino boxes arranged in a gentle curve.
// The first domino gets an impulse, creating a chain reaction.
// Visually satisfying cascade across the screen.
//
// Compile: see README.md

#include "box2d/math_functions.h"
#include "physics_common.h"

#define DOMINO_COUNT 30
#define DOMINO_HW 0.1f     // half-width (thin)
#define DOMINO_HH 0.8f     // half-height (tall)
#define SPACING 1.2f       // spacing between dominoes
#define CURVE_RADIUS 25.0f // radius of the curved arrangement

static void setup_scene(void) {
  // Ground: a wide flat surface
  add_static_segment(-25.0f, 0.0f, 25.0f, 0.0f);

  // Arrange dominoes in a gentle arc
  float start_angle = -0.5f; // radians
  float angle_step = 1.0f / (float)(DOMINO_COUNT - 1);

  for (int i = 0; i < DOMINO_COUNT; i++) {
    float angle = start_angle + (float)i * angle_step;
    float x = CURVE_RADIUS * angle;
    float y = DOMINO_HH; // resting on ground

    add_dynamic_box(x, y, DOMINO_HW, DOMINO_HH);
  }

  // Give the first domino a push
  b2Body_ApplyLinearImpulseToCenter(g_bodies[0], (b2Vec2){3.0f, 0.0f}, true);
}
