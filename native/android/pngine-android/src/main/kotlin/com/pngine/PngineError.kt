/**
 * Error codes returned by PNGine functions.
 * Maps directly to PngineError enum in pngine.h
 *
 * Mirrors iOS PngineKit.swift PngineError enum.
 */
package com.pngine

enum class PngineError(val code: Int) {
    OK(0),
    NOT_INITIALIZED(-1),
    ALREADY_INITIALIZED(-2),
    CONTEXT_FAILED(-3),
    BYTECODE_INVALID(-4),
    SURFACE_FAILED(-5),
    SHADER_COMPILE(-6),
    PIPELINE_CREATE(-7),
    TEXTURE_UNAVAILABLE(-8),
    RESOURCE_NOT_FOUND(-9),
    OUT_OF_MEMORY(-10),
    INVALID_ARGUMENT(-11),
    RENDER_FAILED(-12),
    COMPUTE_FAILED(-13);

    /** Human-readable error description. */
    val description: String
        get() = when (this) {
            OK -> "Success"
            NOT_INITIALIZED -> "PNGine runtime not initialized"
            ALREADY_INITIALIZED -> "PNGine runtime already initialized"
            CONTEXT_FAILED -> "GPU context creation failed"
            BYTECODE_INVALID -> "Invalid bytecode format"
            SURFACE_FAILED -> "Surface creation failed"
            SHADER_COMPILE -> "Shader compilation failed"
            PIPELINE_CREATE -> "Pipeline creation failed"
            TEXTURE_UNAVAILABLE -> "Surface texture unavailable"
            RESOURCE_NOT_FOUND -> "Resource ID not found"
            OUT_OF_MEMORY -> "Out of GPU memory"
            INVALID_ARGUMENT -> "Invalid argument"
            RENDER_FAILED -> "Render pass failed"
            COMPUTE_FAILED -> "Compute pass failed"
        }

    companion object {
        /** Create from raw C error code. */
        fun fromCode(code: Int): PngineError =
            entries.find { it.code == code } ?: RENDER_FAILED
    }
}
