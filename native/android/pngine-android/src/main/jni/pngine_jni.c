/**
 * @file pngine_jni.c
 * @brief JNI bridge for PNGine on Android
 *
 * Provides JNI bindings between Kotlin and the PNGine C API.
 */

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <string.h>

#include "pngine.h"

// ============================================================================
// Initialization
// ============================================================================

JNIEXPORT jint JNICALL
Java_com_pngine_PngineView_nativeInit(JNIEnv* env, jobject thiz) {
    (void)env;
    (void)thiz;
    return pngine_init();
}

JNIEXPORT void JNICALL
Java_com_pngine_PngineView_nativeShutdown(JNIEnv* env, jobject thiz) {
    (void)env;
    (void)thiz;
    pngine_shutdown();
}

JNIEXPORT jboolean JNICALL
Java_com_pngine_PngineView_nativeIsInitialized(JNIEnv* env, jobject thiz) {
    (void)env;
    (void)thiz;
    return pngine_is_initialized() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_pngine_PngineView_nativeMemoryWarning(JNIEnv* env, jobject thiz) {
    (void)env;
    (void)thiz;
    pngine_memory_warning();
}

// ============================================================================
// Animation Lifecycle
// ============================================================================

JNIEXPORT jlong JNICALL
Java_com_pngine_PngineView_nativeCreate(
    JNIEnv* env,
    jobject thiz,
    jbyteArray bytecode,
    jobject surface,
    jint width,
    jint height
) {
    (void)thiz;

    // Get native window from Surface
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (window == NULL) {
        return 0;
    }

    // Get bytecode bytes
    jbyte* bytecode_ptr = (*env)->GetByteArrayElements(env, bytecode, NULL);
    jsize bytecode_len = (*env)->GetArrayLength(env, bytecode);

    // Create animation
    PngineAnimation* anim = pngine_create(
        (const uint8_t*)bytecode_ptr,
        (size_t)bytecode_len,
        window,
        (uint32_t)width,
        (uint32_t)height
    );

    // Release bytecode array
    (*env)->ReleaseByteArrayElements(env, bytecode, bytecode_ptr, JNI_ABORT);

    // Note: We don't release the native window here because PNGine needs it
    // It will be released when the animation is destroyed

    return (jlong)anim;
}

JNIEXPORT void JNICALL
Java_com_pngine_PngineView_nativeRender(
    JNIEnv* env,
    jobject thiz,
    jlong ptr,
    jfloat time
) {
    (void)env;
    (void)thiz;

    PngineAnimation* anim = (PngineAnimation*)ptr;
    if (anim != NULL) {
        pngine_render(anim, time);
    }
}

JNIEXPORT void JNICALL
Java_com_pngine_PngineView_nativeResize(
    JNIEnv* env,
    jobject thiz,
    jlong ptr,
    jint width,
    jint height
) {
    (void)env;
    (void)thiz;

    PngineAnimation* anim = (PngineAnimation*)ptr;
    if (anim != NULL) {
        pngine_resize(anim, (uint32_t)width, (uint32_t)height);
    }
}

JNIEXPORT void JNICALL
Java_com_pngine_PngineView_nativeDestroy(
    JNIEnv* env,
    jobject thiz,
    jlong ptr
) {
    (void)env;
    (void)thiz;

    PngineAnimation* anim = (PngineAnimation*)ptr;
    if (anim != NULL) {
        pngine_destroy(anim);
    }
}

JNIEXPORT jstring JNICALL
Java_com_pngine_PngineView_nativeGetError(JNIEnv* env, jobject thiz) {
    (void)thiz;

    const char* error = pngine_get_error();
    if (error == NULL) {
        return NULL;
    }
    return (*env)->NewStringUTF(env, error);
}

// ============================================================================
// Companion Object Methods
// ============================================================================

JNIEXPORT jstring JNICALL
Java_com_pngine_PngineView_00024Companion_version(JNIEnv* env, jobject thiz) {
    (void)thiz;
    return (*env)->NewStringUTF(env, pngine_version());
}
