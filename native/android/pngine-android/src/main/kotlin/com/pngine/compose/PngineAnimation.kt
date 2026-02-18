/**
 * PngineAnimation — Jetpack Compose composable for PNGine animations.
 *
 * Wraps PngineView via AndroidView since GPU rendering via Vulkan
 * cannot go through Compose's Canvas (unlike Lottie which uses Canvas API).
 *
 * Usage:
 * ```kotlin
 * @Composable
 * fun MyScreen() {
 *     PngineAnimation(
 *         bytecode = myBytecodeData,
 *         modifier = Modifier.size(300.dp),
 *     )
 * }
 * ```
 *
 * Controlled playback:
 * ```kotlin
 * var isPlaying by remember { mutableStateOf(true) }
 *
 * PngineAnimation(
 *     bytecode = data,
 *     isPlaying = isPlaying,
 * )
 *
 * Button(onClick = { isPlaying = !isPlaying }) {
 *     Text(if (isPlaying) "Pause" else "Play")
 * }
 * ```
 */
package com.pngine.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.pngine.PngineBackgroundBehavior
import com.pngine.PngineView

/**
 * Composable that displays a PNGine animation.
 *
 * @param bytecode The PNGine bytecode data to render.
 * @param modifier Compose modifier for layout.
 * @param isPlaying Whether the animation should be playing. Defaults to true.
 * @param speed Animation playback speed multiplier. Default is 1.0.
 * @param backgroundBehavior Controls behavior when app enters background.
 */
@Composable
fun PngineAnimation(
    bytecode: ByteArray,
    modifier: Modifier = Modifier,
    isPlaying: Boolean = true,
    speed: Float = 1.0f,
    backgroundBehavior: PngineBackgroundBehavior = PngineBackgroundBehavior.PAUSE_AND_RESTORE,
) {
    val context = LocalContext.current

    // Remember the bytecode identity to detect changes
    val bytecodeKey = remember(bytecode) { bytecode }

    AndroidView(
        factory = { ctx ->
            PngineView(ctx).apply {
                this.backgroundBehavior = backgroundBehavior
                this.animationSpeed = speed
                load(bytecodeKey)
                if (isPlaying) {
                    play()
                }
            }
        },
        modifier = modifier,
        update = { view ->
            view.backgroundBehavior = backgroundBehavior
            view.animationSpeed = speed

            // Sync playback state
            if (isPlaying && !view.isPlaying) {
                view.play()
            } else if (!isPlaying && view.isPlaying) {
                view.pause()
            }
        },
    )
}
