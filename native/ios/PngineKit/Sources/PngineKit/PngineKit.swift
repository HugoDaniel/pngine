/**
 * PngineKit - Swift bindings for PNGine
 *
 * This module provides Swift wrappers for the PNGine native C API.
 * Use PngineView for SwiftUI or PngineAnimationView for UIKit/AppKit.
 */

import Foundation

// Re-export the C API functions
// These are imported from the PngineCore binary target

@_silgen_name("pngine_init")
public func pngine_init() -> Int32

@_silgen_name("pngine_shutdown")
public func pngine_shutdown()

@_silgen_name("pngine_is_initialized")
public func pngine_is_initialized() -> Bool

@_silgen_name("pngine_memory_warning")
public func pngine_memory_warning()

@_silgen_name("pngine_create")
public func pngine_create(
    _ bytecode: UnsafePointer<UInt8>?,
    _ bytecodeLen: Int,
    _ surfaceHandle: UnsafeMutableRawPointer?,
    _ width: UInt32,
    _ height: UInt32
) -> OpaquePointer?

@_silgen_name("pngine_render")
public func pngine_render(_ anim: OpaquePointer?, _ time: Float)

@_silgen_name("pngine_resize")
public func pngine_resize(_ anim: OpaquePointer?, _ width: UInt32, _ height: UInt32)

@_silgen_name("pngine_destroy")
public func pngine_destroy(_ anim: OpaquePointer?)

@_silgen_name("pngine_get_error")
public func pngine_get_error() -> UnsafePointer<CChar>?

@_silgen_name("pngine_get_width")
public func pngine_get_width(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_get_height")
public func pngine_get_height(_ anim: OpaquePointer?) -> UInt32

@_silgen_name("pngine_version")
public func pngine_version() -> UnsafePointer<CChar>

@_silgen_name("pngine_debug_status")
public func pngine_debug_status(_ anim: OpaquePointer?) -> Int32

@_silgen_name("pngine_debug_frame")
public func pngine_debug_frame(_ anim: OpaquePointer?, _ time: Float) -> Int32

@_silgen_name("pngine_debug_render_pass_status")
public func pngine_debug_render_pass_status(_ anim: OpaquePointer?) -> Int32

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
