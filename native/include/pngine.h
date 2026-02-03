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
 * // Set error callback (optional, for debugging)
 * pngine_set_error_callback(my_error_handler, user_data);
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
 *     int result = pngine_render(anim, time);
 *     if (result != 0) {
 *         // Handle render error
 *     }
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

// ============================================================================
// Error Codes
// ============================================================================

/**
 * @brief Error codes returned by PNGine functions.
 */
typedef enum PngineError {
    PNGINE_OK = 0,                      /**< Success */
    PNGINE_ERROR_NOT_INITIALIZED = -1,  /**< pngine_init() not called */
    PNGINE_ERROR_ALREADY_INITIALIZED = -2, /**< pngine_init() already called */
    PNGINE_ERROR_CONTEXT_FAILED = -3,   /**< GPU context creation failed */
    PNGINE_ERROR_BYTECODE_INVALID = -4, /**< Invalid bytecode format */
    PNGINE_ERROR_SURFACE_FAILED = -5,   /**< Surface creation failed */
    PNGINE_ERROR_SHADER_COMPILE = -6,   /**< Shader compilation failed */
    PNGINE_ERROR_PIPELINE_CREATE = -7,  /**< Pipeline creation failed */
    PNGINE_ERROR_TEXTURE_UNAVAIL = -8,  /**< Surface texture unavailable */
    PNGINE_ERROR_RESOURCE_NOT_FOUND = -9, /**< Resource ID not found */
    PNGINE_ERROR_OUT_OF_MEMORY = -10,   /**< Memory allocation failed */
    PNGINE_ERROR_INVALID_ARGUMENT = -11, /**< Invalid argument */
    PNGINE_ERROR_RENDER_FAILED = -12,   /**< Render pass failed */
    PNGINE_ERROR_COMPUTE_FAILED = -13,  /**< Compute pass failed */
} PngineError;

/**
 * @brief Error callback function type.
 *
 * @param error Error code from PngineError enum.
 * @param message Human-readable error message (valid only during callback).
 * @param anim Animation that caused the error, or NULL for global errors.
 * @param user_data User data passed to pngine_set_error_callback().
 */
typedef void (*PngineErrorCallback)(
    PngineError error,
    const char* message,
    struct PngineAnimation* anim,
    void* user_data
);

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
// Error Handling
// ============================================================================

/**
 * @brief Set the error callback for receiving error notifications.
 *
 * The callback is invoked when errors occur during GPU operations.
 * Only one callback can be set; subsequent calls replace the previous.
 * Pass NULL to disable error callbacks.
 *
 * Thread Safety: The callback may be invoked from any thread that calls
 * PNGine functions. Ensure your callback is thread-safe.
 *
 * @param callback Error callback function, or NULL to disable.
 * @param user_data User data passed to the callback.
 */
void pngine_set_error_callback(PngineErrorCallback callback, void* user_data);

/**
 * @brief Get the error message for an error code.
 *
 * @param error Error code from PngineError enum.
 * @return Static string describing the error.
 */
const char* pngine_error_string(PngineError error);

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
 * @return PNGINE_OK on success, or an error code.
 */
PngineError pngine_render(PngineAnimation* anim, float time);

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

/**
 * @brief Debug: Get animation status.
 *
 * @param anim Animation handle.
 * @return Status code:
 *         0 = OK
 *         -1 = No animation
 *         -2 = No surface
 *         -3 = No device
 *         -4 = No pipeline
 *         -5 = No shader
 */
int pngine_debug_status(PngineAnimation* anim);

/**
 * @brief Debug: Execute one frame and return status.
 *
 * @param anim Animation handle.
 * @param time Time in seconds.
 * @return Status code:
 *         0 = OK
 *         -10 = Surface texture unavailable
 *         -11 = No surface configured
 *         -12 = Texture not found
 *         -13 = Invalid resource ID
 *         -14 = Shader compilation failed
 *         -15 = Pipeline creation failed
 *         -99 = Other error
 */
int pngine_debug_frame(PngineAnimation* anim, float time);

/**
 * @brief Debug: Get render pass status after frame execution.
 *
 * @param anim Animation handle.
 * @return Status code:
 *         0 = Properly cleaned up
 *         1 = Encoder still active
 *         2 = Render pass still active
 */
int pngine_debug_render_pass_status(PngineAnimation* anim);

// ============================================================================
// Per-Animation Diagnostics
// ============================================================================

/**
 * @brief Get last error for a specific animation.
 *
 * @param anim Animation handle.
 * @return Last error code for this animation.
 */
PngineError pngine_anim_get_last_error(PngineAnimation* anim);

/**
 * @brief Get compute counters for a specific animation.
 *
 * @param anim Animation handle.
 * @return Packed counters: [passes:8][pipelines:8][bindgroups:8][dispatches:8]
 */
uint32_t pngine_anim_compute_counters(PngineAnimation* anim);

/**
 * @brief Get render counters for a specific animation.
 *
 * @param anim Animation handle.
 * @return Packed counters: [render_passes:16][draws:16]
 */
uint32_t pngine_anim_render_counters(PngineAnimation* anim);

/**
 * @brief Get total frame count for a specific animation.
 *
 * @param anim Animation handle.
 * @return Number of frames rendered since creation.
 */
uint32_t pngine_anim_frame_count(PngineAnimation* anim);

/**
 * @brief Reset diagnostics counters for an animation.
 *
 * Useful for per-frame diagnostics.
 *
 * @param anim Animation handle.
 */
void pngine_anim_reset_counters(PngineAnimation* anim);

// ============================================================================
// Deprecated Global Diagnostics (prefer per-animation versions)
// ============================================================================

/** @deprecated Use pngine_anim_compute_counters() instead */
uint32_t pngine_debug_compute_counters(void);

/** @deprecated Use pngine_anim_render_counters() instead */
uint32_t pngine_debug_render_counters(void);

/** @deprecated Use pngine_anim_* functions instead */
uint32_t pngine_debug_buffer_ids(void);

/** @deprecated Use pngine_anim_* functions instead */
uint32_t pngine_debug_first_buffer_ids(void);

/** @deprecated Use pngine_anim_* functions instead */
uint32_t pngine_debug_buffer_0_size(void);

/** @deprecated Use pngine_anim_* functions instead */
uint32_t pngine_debug_dispatch_x(void);

/** @deprecated Use pngine_anim_* functions instead */
uint32_t pngine_debug_draw_info(void);

#ifdef __cplusplus
}
#endif

#endif /* PNGINE_H */
