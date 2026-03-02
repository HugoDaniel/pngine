// Box2D v3 WASM Physics Shim — Common Header
//
// Shared interface for all Box2D physics demos compiled to WASM.
// Each demo implements physics_init() with a different scene setup.
//
// Compile: zig cc -target wasm32-freestanding -O2 <demo>.c box2d/src/*.c -o
// <demo>.wasm

#pragma once

#include "box2d/box2d.h"

#include <stdbool.h>

// Maximum bodies we track for transform extraction
#define MAX_BODIES 256

// Output transform: x, y, cos(angle), sin(angle) per body
#define FLOATS_PER_BODY 4

// Global state — persists across frames in WASM linear memory
static b2WorldId g_world;
static b2BodyId g_bodies[MAX_BODIES];
static int g_body_count = 0;
static bool g_initialized = false;

// Transform output buffer in WASM linear memory
static float g_transform_buf[MAX_BODIES * FLOATS_PER_BODY];

// ============================================================================
// Demo-specific: each demo implements this
// ============================================================================
static void setup_scene(void);

// ============================================================================
// Exported WASM functions (called via pngine #wasmCall)
// ============================================================================

// Initialize physics world + scene (idempotent — safe to call every frame)
__attribute__((export_name("physics_init"))) void physics_init(void) {
  if (g_initialized)
    return;
  g_initialized = true;

  b2WorldDef worldDef = b2DefaultWorldDef();
  worldDef.gravity = (b2Vec2){0.0f, -10.0f};
  g_world = b2CreateWorld(&worldDef);

  setup_scene();
}

// Step the physics simulation by dt seconds
// Define CUSTOM_PHYSICS_STEP before including this header to override
#ifndef CUSTOM_PHYSICS_STEP
__attribute__((export_name("physics_step"))) void physics_step(float dt) {
  if (!g_initialized)
    physics_init();
  b2World_Step(g_world, dt, 4);
}
#endif

// Pack all body transforms into output buffer, return float count
__attribute__((export_name("physics_get_transforms"))) int
physics_get_transforms(void) {
  for (int i = 0; i < g_body_count; i++) {
    b2Vec2 pos = b2Body_GetPosition(g_bodies[i]);
    b2Rot rot = b2Body_GetRotation(g_bodies[i]);
    g_transform_buf[i * FLOATS_PER_BODY + 0] = pos.x;
    g_transform_buf[i * FLOATS_PER_BODY + 1] = pos.y;
    g_transform_buf[i * FLOATS_PER_BODY + 2] = rot.c; // cos(angle)
    g_transform_buf[i * FLOATS_PER_BODY + 3] = rot.s; // sin(angle)
  }
  return g_body_count * FLOATS_PER_BODY;
}

// Get pointer to transform buffer (for WASM memory read)
__attribute__((export_name("physics_get_transform_ptr"))) float *
physics_get_transform_ptr(void) {
  return g_transform_buf;
}

// Get body count
__attribute__((export_name("physics_get_body_count"))) int
physics_get_body_count(void) {
  return g_body_count;
}

// Trigger an explosion at (x, y) — used by tower demo
__attribute__((export_name("physics_explode"))) void
physics_explode(float x, float y, float radius, float impulse) {
  if (!g_initialized)
    return;
  b2ExplosionDef explosionDef = b2DefaultExplosionDef();
  explosionDef.position = (b2Vec2){x, y};
  explosionDef.radius = radius;
  explosionDef.impulsePerLength = impulse;
  b2World_Explode(g_world, &explosionDef);
}

// ============================================================================
// Helper to add a dynamic body
// ============================================================================
static inline b2BodyId add_dynamic_box(float x, float y, float hw, float hh) {
  b2BodyDef bodyDef = b2DefaultBodyDef();
  bodyDef.type = b2_dynamicBody;
  bodyDef.position = (b2Vec2){x, y};
  b2BodyId body = b2CreateBody(g_world, &bodyDef);

  b2ShapeDef shapeDef = b2DefaultShapeDef();
  shapeDef.density = 1.0f;
  shapeDef.material.friction = 0.6f;
  shapeDef.material.restitution = 0.1f;
  b2Polygon box = b2MakeBox(hw, hh);
  b2CreatePolygonShape(body, &shapeDef, &box);

  if (g_body_count < MAX_BODIES) {
    g_bodies[g_body_count++] = body;
  }
  return body;
}

static inline b2BodyId add_dynamic_circle(float x, float y, float radius) {
  b2BodyDef bodyDef = b2DefaultBodyDef();
  bodyDef.type = b2_dynamicBody;
  bodyDef.position = (b2Vec2){x, y};
  b2BodyId body = b2CreateBody(g_world, &bodyDef);

  b2ShapeDef shapeDef = b2DefaultShapeDef();
  shapeDef.density = 1.0f;
  shapeDef.material.friction = 0.3f;
  shapeDef.material.restitution = 0.5f;
  b2Circle circle = {{0.0f, 0.0f}, radius};
  b2CreateCircleShape(body, &shapeDef, &circle);

  if (g_body_count < MAX_BODIES) {
    g_bodies[g_body_count++] = body;
  }
  return body;
}

static inline void add_static_segment(float x1, float y1, float x2, float y2) {
  b2BodyDef bodyDef = b2DefaultBodyDef();
  b2BodyId body = b2CreateBody(g_world, &bodyDef);

  b2ShapeDef shapeDef = b2DefaultShapeDef();
  shapeDef.material.friction = 0.8f;
  b2Segment segment = {{x1, y1}, {x2, y2}};
  b2CreateSegmentShape(body, &shapeDef, &segment);
}

static inline void add_static_box(float x, float y, float hw, float hh) {
  b2BodyDef bodyDef = b2DefaultBodyDef();
  bodyDef.position = (b2Vec2){x, y};
  b2BodyId body = b2CreateBody(g_world, &bodyDef);

  b2ShapeDef shapeDef = b2DefaultShapeDef();
  shapeDef.material.friction = 0.8f;
  b2Polygon box = b2MakeBox(hw, hh);
  b2CreatePolygonShape(body, &shapeDef, &box);
}
