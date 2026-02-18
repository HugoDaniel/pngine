/**
 * AsyncPngineAnimation — Async-loading Compose composable for PNGine animations.
 *
 * Mirrors iOS AsyncPngineView. Loads bytecode asynchronously via a suspend function
 * and shows a placeholder while loading.
 *
 * Usage:
 * ```kotlin
 * @Composable
 * fun MyScreen() {
 *     AsyncPngineAnimation(
 *         load = { loadBytecodeFromNetwork() },
 *         modifier = Modifier.size(300.dp),
 *     ) {
 *         CircularProgressIndicator()
 *     }
 * }
 * ```
 */
package com.pngine.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.pngine.Pngine
import com.pngine.PngineBackgroundBehavior

/**
 * Composable that loads animation bytecode asynchronously with a placeholder.
 *
 * @param load Suspend function that returns the bytecode data.
 * @param modifier Compose modifier for layout.
 * @param isPlaying Whether the animation should be playing once loaded. Defaults to true.
 * @param speed Animation playback speed multiplier. Default is 1.0.
 * @param backgroundBehavior Controls behavior when app enters background.
 * @param placeholder Composable to show while loading or on error.
 */
@Composable
fun AsyncPngineAnimation(
    load: suspend () -> ByteArray,
    modifier: Modifier = Modifier,
    isPlaying: Boolean = true,
    speed: Float = 1.0f,
    backgroundBehavior: PngineBackgroundBehavior = PngineBackgroundBehavior.PAUSE_AND_RESTORE,
    placeholder: @Composable () -> Unit = {},
) {
    var bytecode by remember { mutableStateOf<ByteArray?>(null) }
    var loadError by remember { mutableStateOf<Throwable?>(null) }

    LaunchedEffect(load) {
        try {
            bytecode = load()
        } catch (e: Throwable) {
            loadError = e
            Pngine.logger.error("Failed to load bytecode: ${e.message}")
        }
    }

    val loadedBytecode = bytecode
    if (loadedBytecode != null) {
        PngineAnimation(
            bytecode = loadedBytecode,
            modifier = modifier,
            isPlaying = isPlaying,
            speed = speed,
            backgroundBehavior = backgroundBehavior,
        )
    } else {
        placeholder()
    }
}
