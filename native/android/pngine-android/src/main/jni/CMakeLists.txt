cmake_minimum_required(VERSION 3.22.1)
project("pngine-jni" C)

# Path to pngine.h header (passed from build.gradle.kts)
if(NOT DEFINED PNGINE_INCLUDE_DIR)
    set(PNGINE_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/include")
endif()

# Build the JNI bridge as a shared library
add_library(pngine-jni SHARED pngine_jni.c)

# Include pngine.h header
target_include_directories(pngine-jni PRIVATE ${PNGINE_INCLUDE_DIR})

# Link against the pre-built pngine library from Zig cross-compilation
# The .so files should be placed in src/main/jniLibs/{abi}/
add_library(pngine SHARED IMPORTED)
set_target_properties(pngine PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libpngine.so"
)
target_link_libraries(pngine-jni pngine)

# Link Android system libraries
find_library(log-lib log)
find_library(android-lib android)
target_link_libraries(pngine-jni ${log-lib} ${android-lib})
