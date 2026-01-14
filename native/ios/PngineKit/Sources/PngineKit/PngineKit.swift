/**
 * PngineKit - Swift bindings for PNGine
 *
 * This module provides Swift wrappers for the PNGine native C API.
 * Use PngineView for SwiftUI or PngineAnimationView for UIKit/AppKit.
 */

import Foundation

// MARK: - Error Types

/// Error codes returned by PNGine functions.
/// Maps directly to PngineError enum in pngine.h
public enum PngineError: Int32, Error, LocalizedError {
    case ok = 0
    case notInitialized = -1
    case alreadyInitialized = -2
    case contextFailed = -3
    case bytecodeInvalid = -4
    case surfaceFailed = -5
    case shaderCompile = -6
    case pipelineCreate = -7
    case textureUnavailable = -8
    case resourceNotFound = -9
    case outOfMemory = -10
    case invalidArgument = -11
    case renderFailed = -12
    case computeFailed = -13

    public var errorDescription: String? {
        switch self {
        case .ok:
            return nil
        case .notInitialized:
            return "PNGine runtime not initialized"
        case .alreadyInitialized:
            return "PNGine runtime already initialized"
        case .contextFailed:
            return "GPU context creation failed"
        case .bytecodeInvalid:
            return "Invalid bytecode format"
        case .surfaceFailed:
            return "Surface creation failed"
        case .shaderCompile:
            return "Shader compilation failed"
        case .pipelineCreate:
            return "Pipeline creation failed"
        case .textureUnavailable:
            return "Surface texture unavailable"
        case .resourceNotFound:
            return "Resource ID not found"
        case .outOfMemory:
            return "Out of GPU memory"
        case .invalidArgument:
            return "Invalid argument"
        case .renderFailed:
            return "Render pass failed"
        case .computeFailed:
            return "Compute pass failed"
        }
    }

    /// Create from raw C error code.
    public init(rawValue: Int32) {
        switch rawValue {
        case 0: self = .ok
        case -1: self = .notInitialized
        case -2: self = .alreadyInitialized
        case -3: self = .contextFailed
        case -4: self = .bytecodeInvalid
        case -5: self = .surfaceFailed
        case -6: self = .shaderCompile
        case -7: self = .pipelineCreate
        case -8: self = .textureUnavailable
        case -9: self = .resourceNotFound
        case -10: self = .outOfMemory
        case -11: self = .invalidArgument
        case -12: self = .renderFailed
        case -13: self = .computeFailed
        default: self = .renderFailed // Unknown error
        }
    }
}

// MARK: - Logger Protocol

/// Protocol for logging PNGine events and errors.
public protocol PngineLogger {
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

/// Default logger that prints to console.
public class DefaultPngineLogger: PngineLogger {
    public static let shared = DefaultPngineLogger()

    private init() {}

    public func info(_ message: String) {
        #if DEBUG
        print("[PngineKit] \(message)")
        #endif
    }

    public func warn(_ message: String) {
        print("[PngineKit] Warning: \(message)")
    }

    public func error(_ message: String) {
        print("[PngineKit] Error: \(message)")
    }
}

/// Current logger instance. Set to customize logging behavior.
public var pngineLogger: PngineLogger = DefaultPngineLogger.shared

// MARK: - Error Callback

/// Type for C error callback function.
public typealias PngineErrorCallback = @convention(c) (
    Int32,                   // error code
    UnsafePointer<CChar>?,   // message
    OpaquePointer?,          // animation (may be null)
    UnsafeMutableRawPointer? // user_data
) -> Void

// MARK: - C API Bindings - Initialization

@_silgen_name("pngine_init")
public func pngine_init() -> Int32

@_silgen_name("pngine_shutdown")
public func pngine_shutdown()

@_silgen_name("pngine_is_initialized")
public func pngine_is_initialized() -> Bool

@_silgen_name("pngine_memory_warning")
public func pngine_memory_warning()

// MARK: - C API Bindings - Error Handling

@_silgen_name("pngine_set_error_callback")
public func pngine_set_error_callback(
    _ callback: PngineErrorCallback?,
    _ userData: UnsafeMutableRawPointer?
)

@_silgen_name("pngine_error_string")
public func pngine_error_string(_ error: Int32) -> UnsafePointer<CChar>?

@_silgen_name("pngine_get_error")
public func pngine_get_error() -> UnsafePointer<CChar>?

// MARK: - C API Bindings - Animation Lifecycle

@_silgen_name("pngine_create")
public func pngine_create(
    _ bytecode: UnsafePointer<UInt8>?,
    _ bytecodeLen: Int,
    _ surfaceHandle: UnsafeMutableRawPointer?,
    _ width: UInt32,
    _ height: UInt32
) -> OpaquePointer?

@_silgen_name("pngine_render")
public func pngine_render(_ anim: OpaquePointer?, _ time: Float) -> Int32

@_silgen_name("pngine_resize")
public func pngine_resize(_ anim: OpaquePointer?, _ width: UInt32, _ height: UInt32)

@_silgen_name("pngine_destroy")
public func pngine_destroy(_ anim: OpaquePointer?)

// MARK: - C API Bindings - Utilities

@_silgen_name("pngine_get_width")
public func pngine_get_width(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_get_height")
public func pngine_get_height(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_version")
public func pngine_version() -> UnsafePointer<CChar>

// MARK: - C API Bindings - Debug

@_silgen_name("pngine_debug_status")
public func pngine_debug_status(_ anim: OpaquePointer?) -> Int32

@_silgen_name("pngine_debug_frame")
public func pngine_debug_frame(_ anim: OpaquePointer?, _ time: Float) -> Int32

@_silgen_name("pngine_debug_render_pass_status")
public func pngine_debug_render_pass_status(_ anim: OpaquePointer?) -> Int32

// MARK: - C API Bindings - Per-Animation Diagnostics

@_silgen_name("pngine_anim_get_last_error")
public func pngine_anim_get_last_error(_ anim: OpaquePointer?) -> Int32

@_silgen_name("pngine_anim_compute_counters")
public func pngine_anim_compute_counters(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_anim_render_counters")
public func pngine_anim_render_counters(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_anim_frame_count")
public func pngine_anim_frame_count(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_anim_reset_counters")
public func pngine_anim_reset_counters(_ anim: OpaquePointer?)

// MARK: - C API Bindings - Deprecated Global Diagnostics

@available(*, deprecated, message: "Use pngine_anim_compute_counters() instead")
@_silgen_name("pngine_debug_compute_counters")
public func pngine_debug_compute_counters() -> UInt32

@available(*, deprecated, message: "Use pngine_anim_render_counters() instead")
@_silgen_name("pngine_debug_render_counters")
public func pngine_debug_render_counters() -> UInt32

@available(*, deprecated, message: "Use pngine_anim_* functions instead")
@_silgen_name("pngine_debug_buffer_ids")
public func pngine_debug_buffer_ids() -> UInt32

@available(*, deprecated, message: "Use pngine_anim_* functions instead")
@_silgen_name("pngine_debug_first_buffer_ids")
public func pngine_debug_first_buffer_ids() -> UInt32

@available(*, deprecated, message: "Use pngine_anim_* functions instead")
@_silgen_name("pngine_debug_buffer_0_size")
public func pngine_debug_buffer_0_size() -> UInt32

@available(*, deprecated, message: "Use pngine_anim_* functions instead")
@_silgen_name("pngine_debug_dispatch_x")
public func pngine_debug_dispatch_x() -> UInt32

@available(*, deprecated, message: "Use pngine_anim_* functions instead")
@_silgen_name("pngine_debug_draw_info")
public func pngine_debug_draw_info() -> UInt32

// MARK: - Convenience Functions

/// Get PNGine version as a Swift string.
public func pngineVersion() -> String {
    return String(cString: pngine_version())
}

/// Get last error as a Swift string, or nil if no error.
public func pngineLastError() -> String? {
    guard let error = pngine_get_error() else { return nil }
    return String(cString: error)
}

/// Get error description for an error code.
public func pngineErrorString(_ error: PngineError) -> String {
    if let cStr = pngine_error_string(error.rawValue) {
        return String(cString: cStr)
    }
    return error.errorDescription ?? "Unknown error"
}

/// Initialize PNGine with error checking.
/// Returns PngineError.ok on success.
public func pngineInit() -> PngineError {
    let result = pngine_init()
    let error = PngineError(rawValue: result)
    if error != .ok {
        pngineLogger.error("Initialization failed: \(error.errorDescription ?? "unknown")")
    }
    return error
}

/// Render a frame and return any error.
public func pngineRender(_ anim: OpaquePointer?, time: Float) -> PngineError {
    let result = pngine_render(anim, time)
    return PngineError(rawValue: result)
}

/// Get the last error for a specific animation.
public func pngineAnimLastError(_ anim: OpaquePointer?) -> PngineError {
    let result = pngine_anim_get_last_error(anim)
    return PngineError(rawValue: result)
}

/// Unpack compute counters from packed u32.
/// Returns (passes, pipelines, bindGroups, dispatches)
public func unpackComputeCounters(_ packed: UInt32) -> (passes: UInt8, pipelines: UInt8, bindGroups: UInt8, dispatches: UInt8) {
    return (
        passes: UInt8((packed >> 24) & 0xFF),
        pipelines: UInt8((packed >> 16) & 0xFF),
        bindGroups: UInt8((packed >> 8) & 0xFF),
        dispatches: UInt8(packed & 0xFF)
    )
}

/// Unpack render counters from packed u32.
/// Returns (renderPasses, draws)
public func unpackRenderCounters(_ packed: UInt32) -> (renderPasses: UInt16, draws: UInt16) {
    return (
        renderPasses: UInt16((packed >> 16) & 0xFFFF),
        draws: UInt16(packed & 0xFFFF)
    )
}
