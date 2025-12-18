// Video texture sampling utilities for external textures
// Based on WebGPU samples: other/webgpu-samples/sample/videoUploading/

// External texture sampling requires textureSampleBaseClampToEdge
// This is the only sampling function available for texture_external

// Sample video with cover matrix (aspect ratio correction)
// The cover matrix transforms UVs to maintain aspect ratio
fn sampleVideoCover(
  videoTexture: texture_external,
  videoSampler: sampler,
  uv: vec2f,
  coverMatrix: mat3x3f
) -> vec4f {
  let transformedUV = (coverMatrix * vec3f(uv, 1.0)).xy;
  return textureSampleBaseClampToEdge(videoTexture, videoSampler, transformedUV);
}

// Sample video without transformation (direct UV)
fn sampleVideo(
  videoTexture: texture_external,
  videoSampler: sampler,
  uv: vec2f
) -> vec4f {
  return textureSampleBaseClampToEdge(videoTexture, videoSampler, uv);
}

// Compute cover matrix for aspect ratio correction
// This function is typically computed on the CPU and passed as a uniform
// Included here for reference:
//
// const mat = mat3.identity();
// const videoAspect = video.videoWidth / video.videoHeight;
// const canvasAspect = canvas.width / canvas.height;
// const combinedAspect = videoAspect / canvasAspect;
//
// mat3.translate(mat, [0.5, 0.5], mat);
// mat3.scale(
//   mat,
//   combinedAspect > 1 ? [1 / combinedAspect, 1] : [1, combinedAspect],
//   mat
// );
// mat3.translate(mat, [-0.5, -0.5], mat);
