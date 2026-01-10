/**
 * @file pngine.h
 * @brief PNGine Native C API
 *
 * Platform-agnostic C API for PNGine animations.
 * Works on iOS, Android, macOS, Windows, and Linux.
 *
 * @example
 * ```c
 * #include "pngine.h"
 *
 * // Initialize once at app startup
 * if (pngine_init() != 0) {
 *     // Handle initialization error
 * }
 *
 * // Create animation from bytecode
 * PngineAnimation* anim = pngine_create(
 *     bytecode_data, bytecode_len,
 *     surface_handle,  // CAMetalLayer*, ANativeWindow*, HWND, etc.
 *     width, height
 * );
 *
 * // Render loop
 * while (running) {
 *     float time = get_elapsed_time();
 *     pngine_render(anim, time);
 * }
 *
 * // Cleanup
 * pngine_destroy(anim);
 * pngine_shutdown();
 * ```
 */

#ifndef PNGINE_H
#define PNGINE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Opaque animation handle.
 */
typedef struct PngineAnimation PngineAnimation;

// ============================================================================
// Initialization
// ============================================================================

/**
 * @brief Initialize the PNGine runtime.
 *
 * Must be called once before creating any animations.
 * Should be called on the main thread.
 *
 * @return 0 on success, non-zero on failure.
 */
int pngine_init(void);

/**
 * @brief Shutdown the PNGine runtime.
 *
 * Releases all global resources. Call once at application exit.
 * All animations must be destroyed before calling this.
 */
void pngine_shutdown(void);

/**
 * @brief Check if PNGine is initialized.
 *
 * @return true if initialized, false otherwise.
 */
bool pngine_is_initialized(void);

/**
 * @brief Notify runtime of memory pressure.
 *
 * Call this when receiving memory warnings from the OS.
 * Clears caches and releases non-essential resources.
 */
void pngine_memory_warning(void);

// ============================================================================
// Animation Lifecycle
// ============================================================================

/**
 * @brief Create an animation from bytecode.
 *
 * @param bytecode     Pointer to PNGB bytecode data.
 * @param bytecode_len Length of bytecode in bytes.
 * @param surface_handle Platform-specific surface handle:
 *                       - iOS/macOS: CAMetalLayer*
 *                       - Android: ANativeWindow*
 *                       - Windows: HWND
 *                       - Linux: X11 Window or wl_surface*
 * @param width        Surface width in pixels.
 * @param height       Surface height in pixels.
 *
 * @return Animation handle, or NULL on failure.
 */
PngineAnimation* pngine_create(
    const uint8_t* bytecode,
    size_t bytecode_len,
    void* surface_handle,
    uint32_t width,
    uint32_t height
);

/**
 * @brief Render a frame at the specified time.
 *
 * @param anim Animation handle.
 * @param time Time in seconds since animation start.
 */
void pngine_render(PngineAnimation* anim, float time);

/**
 * @brief Resize the animation surface.
 *
 * Call this when the surface/window size changes.
 *
 * @param anim   Animation handle.
 * @param width  New width in pixels.
 * @param height New height in pixels.
 */
void pngine_resize(PngineAnimation* anim, uint32_t width, uint32_t height);

/**
 * @brief Destroy an animation and release its resources.
 *
 * @param anim Animation handle.
 */
void pngine_destroy(PngineAnimation* anim);

// ============================================================================
// Utilities
// ============================================================================

/**
 * @brief Get the last error message.
 *
 * @return Error message string, or NULL if no error.
 */
const char* pngine_get_error(void);

/**
 * @brief Get animation width.
 *
 * @param anim Animation handle.
 * @return Width in pixels.
 */
uint32_t pngine_get_width(PngineAnimation* anim);

/**
 * @brief Get animation height.
 *
 * @param anim Animation handle.
 * @return Height in pixels.
 */
uint32_t pngine_get_height(PngineAnimation* anim);

/**
 * @brief Get PNGine version string.
 *
 * @return Version string (e.g., "0.1.0").
 */
const char* pngine_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PNGINE_H */
