/**
 * Controls animation behavior when the app enters background.
 * Mirrors iOS PngineBackgroundBehavior enum.
 */
package com.pngine

enum class PngineBackgroundBehavior {
    /** Stop rendering and reset time to 0. */
    STOP,

    /** Pause at the current frame. */
    PAUSE,

    /** Pause at the current frame and automatically resume when foregrounded (default). */
    PAUSE_AND_RESTORE
}
