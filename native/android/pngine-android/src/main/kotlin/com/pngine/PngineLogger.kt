/**
 * Logging interface for PNGine events and errors.
 * Mirrors iOS PngineLogger protocol.
 */
package com.pngine

import android.util.Log

/** Protocol for logging PNGine events and errors. */
interface PngineLogger {
    fun info(message: String)
    fun warn(message: String)
    fun error(message: String)
}

/** Default logger that uses android.util.Log. */
class DefaultPngineLogger private constructor() : PngineLogger {
    override fun info(message: String) {
        if (Pngine.isDebug) {
            Log.i(TAG, message)
        }
    }

    override fun warn(message: String) {
        Log.w(TAG, message)
    }

    override fun error(message: String) {
        Log.e(TAG, message)
    }

    companion object {
        private const val TAG = "PngineKit"
        val instance: DefaultPngineLogger = DefaultPngineLogger()
    }
}

/** Global PNGine configuration. Set to customize behavior. */
object Pngine {
    /** Logger instance. Replace with custom implementation to route logs. */
    @JvmStatic
    var logger: PngineLogger = DefaultPngineLogger.instance

    /** Enable verbose info-level logging. Set to true for debug builds. */
    @JvmStatic
    var isDebug: Boolean = false
}
