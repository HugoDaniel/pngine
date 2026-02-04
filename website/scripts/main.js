// PNGine Landing Page Scripts

// ============================================
// Navigation scroll effect
// ============================================
function initNav() {
  const nav = document.querySelector('.nav');
  if (!nav) return;

  const onScroll = () => {
    if (window.scrollY > 20) {
      nav.classList.add('scrolled');
    } else {
      nav.classList.remove('scrolled');
    }
  };

  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll(); // Initial check
}

// ============================================
// Copy button functionality
// ============================================
function initCopyButtons() {
  document.querySelectorAll('.code-block__copy').forEach(btn => {
    btn.addEventListener('click', async () => {
      const codeBlock = btn.closest('.code-block');
      const code = codeBlock.querySelector('code')?.textContent || '';

      try {
        await navigator.clipboard.writeText(code.trim());
        btn.classList.add('copied');
        btn.textContent = 'Copied!';

        setTimeout(() => {
          btn.classList.remove('copied');
          btn.textContent = 'Copy';
        }, 2000);
      } catch (err) {
        console.error('Failed to copy:', err);
      }
    });
  });
}

// ============================================
// WebGPU Demo Initialization
// ============================================
async function initHeroDemo() {
  const canvas = document.getElementById('hero-canvas');
  if (!canvas) return;

  const fallback = document.getElementById('hero-fallback');

  // Check for WebGPU support
  if (!navigator.gpu) {
    console.log('WebGPU not supported');
    if (fallback) fallback.style.display = 'flex';
    return;
  }

  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      if (fallback) fallback.style.display = 'flex';
      return;
    }

    const device = await adapter.requestDevice();
    const ctx = canvas.getContext('webgpu');
    const format = navigator.gpu.getPreferredCanvasFormat();

    ctx.configure({
      device,
      format,
      alphaMode: 'premultiplied',
    });

    // Simple animated gradient shader
    const shaderCode = /* wgsl */`
      struct Uniforms {
        time: f32,
        aspect: f32,
      }

      @group(0) @binding(0) var<uniform> u: Uniforms;

      struct VertexOutput {
        @builtin(position) pos: vec4f,
        @location(0) uv: vec2f,
      }

      @vertex
      fn vs(@builtin(vertex_index) i: u32) -> VertexOutput {
        var positions = array<vec2f, 6>(
          vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
          vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0)
        );
        var out: VertexOutput;
        out.pos = vec4f(positions[i], 0.0, 1.0);
        out.uv = positions[i] * 0.5 + 0.5;
        return out;
      }

      @fragment
      fn fs(in: VertexOutput) -> @location(0) vec4f {
        let uv = in.uv;
        let t = u.time * 0.5;

        // Centered coordinates
        var p = (uv - 0.5) * 2.0;
        p.x *= u.aspect;

        // Animated pattern
        let d = length(p);
        let a = atan2(p.y, p.x);

        // Purple-blue gradient with orange accents
        let wave = sin(d * 8.0 - t * 2.0 + sin(a * 3.0 + t) * 2.0) * 0.5 + 0.5;
        let wave2 = sin(d * 12.0 + t * 1.5 + cos(a * 5.0 - t * 0.7) * 3.0) * 0.5 + 0.5;

        // Color palette matching brand
        let purple = vec3f(0.42, 0.35, 0.80);  // #6A5ACD
        let blue = vec3f(0.25, 0.30, 0.55);
        let orange = vec3f(0.91, 0.36, 0.30);  // #E85D4C

        var col = mix(blue, purple, wave);
        col = mix(col, orange, wave2 * 0.15 * (1.0 - d));

        // Vignette
        let vig = 1.0 - d * 0.4;
        col *= vig;

        // Subtle grid overlay (pixel aesthetic)
        let grid = smoothstep(0.02, 0.0, abs(fract(p.x * 10.0) - 0.5)) +
                   smoothstep(0.02, 0.0, abs(fract(p.y * 10.0) - 0.5));
        col += vec3f(grid * 0.03);

        return vec4f(col, 1.0);
      }
    `;

    const module = device.createShaderModule({ code: shaderCode });

    const pipeline = device.createRenderPipeline({
      layout: 'auto',
      vertex: { module, entryPoint: 'vs' },
      fragment: {
        module,
        entryPoint: 'fs',
        targets: [{ format }],
      },
    });

    const uniformBuffer = device.createBuffer({
      size: 8,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    const bindGroup = device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [{ binding: 0, resource: { buffer: uniformBuffer } }],
    });

    const startTime = performance.now();

    function render() {
      const time = (performance.now() - startTime) / 1000;
      const aspect = canvas.width / canvas.height;

      device.queue.writeBuffer(uniformBuffer, 0, new Float32Array([time, aspect]));

      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: ctx.getCurrentTexture().createView(),
          loadOp: 'clear',
          storeOp: 'store',
          clearValue: { r: 0.04, g: 0.04, b: 0.07, a: 1 },
        }],
      });

      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.draw(6);
      pass.end();

      device.queue.submit([encoder.finish()]);
      requestAnimationFrame(render);
    }

    // Handle canvas resize
    const resizeObserver = new ResizeObserver(entries => {
      for (const entry of entries) {
        const { width, height } = entry.contentRect;
        const dpr = Math.min(window.devicePixelRatio, 2);
        canvas.width = Math.floor(width * dpr);
        canvas.height = Math.floor(height * dpr);
      }
    });
    resizeObserver.observe(canvas);

    // Hide fallback and start rendering
    if (fallback) fallback.style.display = 'none';
    render();

  } catch (err) {
    console.error('WebGPU init failed:', err);
    if (fallback) fallback.style.display = 'flex';
  }
}

// ============================================
// Smooth scroll for anchor links
// ============================================
function initSmoothScroll() {
  document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', (e) => {
      const href = anchor.getAttribute('href');
      if (href === '#') return;

      const target = document.querySelector(href);
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth' });
      }
    });
  });
}

// ============================================
// Initialize everything
// ============================================
document.addEventListener('DOMContentLoaded', () => {
  initNav();
  initCopyButtons();
  initSmoothScroll();
  initHeroDemo();
});
