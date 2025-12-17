/**
 * PNGine WebGPU Backend
 *
 * Implements the GPU operations called by the WASM module.
 * Manages WebGPU resources and translates WASM calls to actual GPU operations.
 *
 * ## Async ImageBitmap Pattern
 *
 * createImageBitmap() is async in browsers - it returns a Promise that decodes
 * the image data. Since WASM execution is synchronous, the decode completes
 * AFTER the draw call on the first frame, causing textures to appear black.
 *
 * Solution: After the first executeAll(), call waitForBitmaps() to wait for
 * all pending ImageBitmap Promises to resolve, then re-execute:
 *
 * ```javascript
 * pngine.executeAll();              // Starts async bitmap decode
 * await pngine.waitForBitmaps();    // Waits for decode to complete
 * pngine.executeAll();              // Re-renders with textures ready
 * ```
 *
 * Version: 2024-12-17-v1
 */

console.log('[PNGineGPU] Module loaded - version 2024-12-17-v1');

export class PNGineGPU {
    /**
     * @param {GPUDevice} device - WebGPU device
     * @param {GPUCanvasContext} context - Canvas context for rendering
     */
    constructor(device, context) {
        this.device = device;
        this.context = context;
        this.memory = null; // Set when WASM is instantiated

        // Resource maps (ID -> GPU resource)
        this.buffers = new Map();
        this.bufferMeta = new Map();  // Buffer ID → { size, usage }
        this.textures = new Map();
        this.samplers = new Map();
        this.shaders = new Map();
        this.pipelines = new Map();
        this.bindGroups = new Map();
        this.imageBitmaps = new Map();  // ImageBitmap ID → ImageBitmap

        // WASM module support
        this.wasmModules = new Map();      // Module ID → { instance, memory }
        this.wasmCallResults = new Map();  // Call ID → { ptr, moduleId }

        // Runtime state for dynamic arguments
        this.currentTime = 0;              // Total time in seconds ($t.total)
        this.deltaTime = 0;                // Delta time since last frame ($t.delta)

        // Render state
        this.commandEncoder = null;
        this.currentPass = null;
        this.passType = null; // 'render' | 'compute'
    }

    /**
     * Set current time for animation.
     * Called before executeAll() to provide time for WASM calls.
     * @param {number} totalTime - Total elapsed time in seconds
     * @param {number} deltaTime - Time since last frame in seconds
     */
    setTime(totalTime, deltaTime = 0) {
        this.currentTime = totalTime;
        this.deltaTime = deltaTime;
    }

    /**
     * Set WASM memory reference for reading data.
     * @param {WebAssembly.Memory} memory
     */
    setMemory(memory) {
        this.memory = memory;
    }

    /**
     * Read a string from WASM memory.
     * @param {number} ptr - Pointer to string data
     * @param {number} len - String length in bytes
     * @returns {string}
     */
    readString(ptr, len) {
        const bytes = new Uint8Array(this.memory.buffer, ptr, len);
        return new TextDecoder().decode(bytes);
    }

    /**
     * Read raw bytes from WASM memory.
     * @param {number} ptr - Pointer to data
     * @param {number} len - Data length in bytes
     * @returns {Uint8Array}
     */
    readBytes(ptr, len) {
        return new Uint8Array(this.memory.buffer, ptr, len);
    }

    // ========================================================================
    // Resource Creation
    // ========================================================================

    /**
     * Create a GPU buffer.
     * Skips creation if buffer already exists (for animation loop support).
     * @param {number} id - Buffer ID
     * @param {number} size - Buffer size in bytes
     * @param {number} usage - Usage flags
     */
    createBuffer(id, size, usage) {
        console.log(`[GPU] createBuffer(${id}), size=${size}, usage=${usage}`);
        // Skip if already exists (allows executeAll in animation loop)
        if (this.buffers.has(id)) {
            console.log(`[GPU]   buffer ${id} already exists, skipping`);
            return;
        }
        const gpuUsage = this.mapBufferUsage(usage);
        const buffer = this.device.createBuffer({
            size,
            usage: gpuUsage,
        });
        this.buffers.set(id, buffer);
        this.bufferMeta.set(id, { size, usage: gpuUsage });
        console.log(`[GPU]   buffer ${id} created: ${buffer ? 'yes' : 'no'}`);
    }

    /**
     * Find the first buffer with UNIFORM usage.
     * @returns {number|null} Buffer ID or null if not found
     */
    findUniformBuffer() {
        for (const [id, meta] of this.bufferMeta) {
            // GPUBufferUsage.UNIFORM = 0x0040 = 64
            if (meta.usage & GPUBufferUsage.UNIFORM) {
                return id;
            }
        }
        return null;
    }

    /**
     * Create a GPU texture.
     * Skips creation if texture already exists (for animation loop support).
     * @param {number} id - Texture ID
     * @param {number} descPtr - Pointer to binary descriptor
     * @param {number} descLen - Descriptor length
     */
    createTexture(id, descPtr, descLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.textures.has(id)) {
            return;
        }
        const bytes = this.readBytes(descPtr, descLen);
        const desc = this.decodeTextureDescriptor(bytes);
        console.log(`[GPU] createTexture(${id}), decoded:`, desc);

        const texture = this.device.createTexture(desc);
        this.textures.set(id, texture);
    }

    /**
     * Create a texture sampler.
     * Skips creation if sampler already exists (for animation loop support).
     * @param {number} id - Sampler ID
     * @param {number} descPtr - Pointer to binary descriptor
     * @param {number} descLen - Descriptor length
     */
    createSampler(id, descPtr, descLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.samplers.has(id)) {
            return;
        }
        const bytes = this.readBytes(descPtr, descLen);
        const desc = this.decodeSamplerDescriptor(bytes);
        console.log(`[GPU] createSampler(${id}), decoded:`, desc);

        const sampler = this.device.createSampler(desc);
        this.samplers.set(id, sampler);
    }

    /**
     * Create a shader module from WGSL code.
     * Skips creation if shader already exists (for animation loop support).
     * @param {number} id - Shader ID
     * @param {number} codePtr - Pointer to WGSL code
     * @param {number} codeLen - Code length
     */
    createShaderModule(id, codePtr, codeLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.shaders.has(id)) {
            return;
        }
        const code = this.readString(codePtr, codeLen);
        console.log(`[GPU] createShaderModule(${id}), code length: ${code.length}`);
        const module = this.device.createShaderModule({ code });
        this.shaders.set(id, module);
    }

    /**
     * Create a render pipeline.
     * Skips creation if pipeline already exists (for animation loop support).
     * @param {number} id - Pipeline ID
     * @param {number} descPtr - Pointer to descriptor JSON
     * @param {number} descLen - Descriptor length
     */
    createRenderPipeline(id, descPtr, descLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.pipelines.has(id)) {
            return;
        }
        const descJson = this.readString(descPtr, descLen);
        console.log(`[GPU] createRenderPipeline(${id}), desc: ${descJson}`);
        const desc = JSON.parse(descJson);

        // Resolve shader module references
        const vertexShader = this.shaders.get(desc.vertex.shader);
        const fragmentShader = desc.fragment ? this.shaders.get(desc.fragment.shader) : null;
        console.log(`[GPU]   vertex shader ${desc.vertex.shader}: ${vertexShader ? 'found' : 'NOT FOUND'}`);
        if (desc.fragment) {
            console.log(`[GPU]   fragment shader ${desc.fragment.shader}: ${fragmentShader ? 'found' : 'NOT FOUND'}`);
        }

        const pipelineDesc = {
            layout: 'auto',
            vertex: {
                module: vertexShader,
                entryPoint: desc.vertex.entryPoint || 'vertexMain',
            },
        };

        // Add primitive state
        if (desc.primitive) {
            pipelineDesc.primitive = {
                topology: desc.primitive.topology || 'triangle-list',
            };
            if (desc.primitive.cullMode) {
                pipelineDesc.primitive.cullMode = desc.primitive.cullMode;
            }
            if (desc.primitive.frontFace) {
                pipelineDesc.primitive.frontFace = desc.primitive.frontFace;
            }
        } else {
            pipelineDesc.primitive = { topology: 'triangle-list' };
        }

        // Add vertex buffer layouts if present
        if (desc.vertex.buffers && desc.vertex.buffers.length > 0) {
            pipelineDesc.vertex.buffers = desc.vertex.buffers;
            console.log(`[GPU]   vertex buffers: ${JSON.stringify(desc.vertex.buffers)}`);
        }

        if (desc.fragment) {
            pipelineDesc.fragment = {
                module: fragmentShader,
                entryPoint: desc.fragment.entryPoint || 'fragmentMain',
                targets: [{
                    format: navigator.gpu.getPreferredCanvasFormat(),
                }],
            };
        }

        // Add depth/stencil state if present
        if (desc.depthStencil) {
            pipelineDesc.depthStencil = {
                format: desc.depthStencil.format || 'depth24plus',
                depthWriteEnabled: desc.depthStencil.depthWriteEnabled !== false,
                depthCompare: desc.depthStencil.depthCompare || 'less',
            };
            console.log(`[GPU]   depthStencil: ${JSON.stringify(pipelineDesc.depthStencil)}`);
        }

        // Add multisample state if present
        if (desc.multisample) {
            pipelineDesc.multisample = desc.multisample;
        }

        const pipeline = this.device.createRenderPipeline(pipelineDesc);
        this.pipelines.set(id, pipeline);
        console.log(`[GPU]   pipeline ${id} created: ${pipeline ? 'yes' : 'no'}`);
    }

    /**
     * Create a compute pipeline.
     * Skips creation if pipeline already exists (for animation loop support).
     * @param {number} id - Pipeline ID
     * @param {number} descPtr - Pointer to descriptor JSON
     * @param {number} descLen - Descriptor length
     */
    createComputePipeline(id, descPtr, descLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.pipelines.has(id)) {
            return;
        }
        const descJson = this.readString(descPtr, descLen);
        const desc = JSON.parse(descJson);

        const pipeline = this.device.createComputePipeline({
            layout: 'auto',
            compute: {
                module: this.shaders.get(desc.compute.shader),
                entryPoint: desc.compute.entryPoint || 'main',
            },
        });
        this.pipelines.set(id, pipeline);
    }

    /**
     * Create a bind group.
     * Skips creation if bind group already exists (for animation loop support).
     * @param {number} id - Bind group ID
     * @param {number} pipelineId - Pipeline ID to get layout from
     * @param {number} entriesPtr - Pointer to binary descriptor
     * @param {number} entriesLen - Descriptor length
     */
    createBindGroup(id, pipelineId, entriesPtr, entriesLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.bindGroups.has(id)) {
            return;
        }
        const bytes = this.readBytes(entriesPtr, entriesLen);
        const desc = this.decodeBindGroupDescriptor(bytes);
        console.log(`[GPU] createBindGroup(${id}), pipeline=${pipelineId}, group=${desc.groupIndex}, entries=${desc.entries.length}`);

        // Resolve resource references in entries
        const entries = desc.entries.map(entry => {
            const resolved = { binding: entry.binding };
            if (entry.resourceType === 0) { // buffer
                resolved.resource = { buffer: this.buffers.get(entry.resourceId) };
            } else if (entry.resourceType === 1) { // texture_view
                const texture = this.textures.get(entry.resourceId);
                resolved.resource = texture.createView();
            } else if (entry.resourceType === 2) { // sampler
                resolved.resource = this.samplers.get(entry.resourceId);
            }
            return resolved;
        });

        // Get layout from pipeline
        const pipeline = this.pipelines.get(pipelineId);
        if (!pipeline) {
            console.error(`[GPU] Pipeline ${pipelineId} not found for bind group ${id}`);
            return;
        }
        const bindGroup = this.device.createBindGroup({
            layout: pipeline.getBindGroupLayout(desc.groupIndex),
            entries,
        });
        this.bindGroups.set(id, bindGroup);
    }

    /**
     * Create an ImageBitmap from blob data.
     * Blob format: [mime_len:u8][mime:bytes][data:bytes]
     * This is async - stores a Promise that resolves to ImageBitmap.
     * @param {number} id - ImageBitmap ID
     * @param {number} blobPtr - Pointer to blob data
     * @param {number} blobLen - Blob data length
     */
    createImageBitmap(id, blobPtr, blobLen) {
        // Skip if already exists (allows executeAll in animation loop)
        if (this.imageBitmaps.has(id)) {
            return;
        }

        const bytes = this.readBytes(blobPtr, blobLen);

        // Parse blob format: [mime_len:u8][mime:bytes][data:bytes]
        const mimeLen = bytes[0];
        const mimeBytes = bytes.slice(1, 1 + mimeLen);
        const mimeType = new TextDecoder().decode(mimeBytes);
        const imageData = bytes.slice(1 + mimeLen);

        console.log(`[GPU] createImageBitmap(${id}), mime=${mimeType}, size=${imageData.length}`);

        // Create Blob and decode to ImageBitmap (async)
        const blob = new Blob([imageData], { type: mimeType });
        const bitmapPromise = window.createImageBitmap(blob);

        // Store the promise - will be awaited when copying to texture
        this.imageBitmaps.set(id, bitmapPromise);
    }

    /**
     * Wait for all pending ImageBitmap decoding to complete.
     * Call this after init phase but before first frame to ensure
     * all textures can be uploaded synchronously.
     * @returns {Promise<void>}
     */
    async waitForBitmaps() {
        const pending = [];
        for (const [id, bitmap] of this.imageBitmaps.entries()) {
            if (bitmap instanceof Promise) {
                pending.push(
                    bitmap.then(resolved => {
                        this.imageBitmaps.set(id, resolved);
                        console.log(`[GPU] ImageBitmap ${id} decoded: ${resolved.width}x${resolved.height}`);
                        return resolved;
                    })
                );
            }
        }
        if (pending.length > 0) {
            console.log(`[GPU] Waiting for ${pending.length} ImageBitmap(s) to decode...`);
            await Promise.all(pending);
            console.log(`[GPU] All ImageBitmaps ready`);
        }
    }

    // ========================================================================
    // WASM Module Operations
    // ========================================================================

    /**
     * Initialize a WASM module from embedded data.
     * The WASM bytes come from the PNGine data section.
     * @param {number} moduleId - Module ID
     * @param {number} dataPtr - Pointer to WASM binary in memory
     * @param {number} dataLen - Length of WASM binary
     */
    initWasmModule(moduleId, dataPtr, dataLen) {
        // Skip if already loaded (allows executeAll in animation loop)
        if (this.wasmModules.has(moduleId)) {
            return;
        }

        const wasmBytes = this.readBytes(dataPtr, dataLen).slice();  // Copy bytes
        console.log(`[GPU] initWasmModule(${moduleId}), size=${wasmBytes.length}`);

        try {
            // Compile synchronously (small modules expected)
            const module = new WebAssembly.Module(wasmBytes);

            // Minimal imports for typical WASM modules
            const imports = {
                env: {
                    abort: (msg, file, line, col) => {
                        console.error(`[WASM abort] ${msg} at ${file}:${line}:${col}`);
                    },
                    // Math imports for AssemblyScript
                    'Math.sin': Math.sin,
                    'Math.cos': Math.cos,
                    'Math.tan': Math.tan,
                    'Math.sqrt': Math.sqrt,
                }
            };

            const instance = new WebAssembly.Instance(module, imports);

            this.wasmModules.set(moduleId, {
                instance,
                memory: instance.exports.memory,
            });

            console.log(`[GPU]   WASM module ${moduleId} loaded, exports:`, Object.keys(instance.exports));
        } catch (err) {
            console.error(`[GPU] Failed to load WASM module ${moduleId}:`, err);
        }
    }

    /**
     * Call a WASM exported function with encoded arguments.
     * The function returns a pointer to data in WASM linear memory.
     *
     * @param {number} callId - Unique call ID for result tracking
     * @param {number} moduleId - Module ID
     * @param {number} funcNamePtr - Pointer to function name string
     * @param {number} funcNameLen - Function name length
     * @param {number} argsPtr - Pointer to encoded arguments
     * @param {number} argsLen - Arguments length
     */
    callWasmFunc(callId, moduleId, funcNamePtr, funcNameLen, argsPtr, argsLen) {
        const wasm = this.wasmModules.get(moduleId);
        if (!wasm) {
            console.error(`[GPU] callWasmFunc: module ${moduleId} not found`);
            return;
        }

        const funcName = this.readString(funcNamePtr, funcNameLen);
        const func = wasm.instance.exports[funcName];

        if (!func) {
            console.error(`[GPU] callWasmFunc: function '${funcName}' not found in module ${moduleId}`);
            return;
        }

        // Decode and resolve arguments
        const encodedArgs = this.readBytes(argsPtr, argsLen);
        const resolvedArgs = this.resolveWasmArgs(encodedArgs);

        console.log(`[GPU] callWasmFunc(${callId}): ${funcName}(${resolvedArgs.join(', ')})`);

        // Call WASM function - returns pointer to result in WASM memory
        const resultPtr = func(...resolvedArgs);

        // Store result for writeBufferFromWasm
        this.wasmCallResults.set(callId, { ptr: resultPtr, moduleId });
        console.log(`[GPU]   result ptr: ${resultPtr}`);
    }

    /**
     * Write data from WASM memory to a GPU buffer.
     * Uses the result pointer from a previous callWasmFunc.
     *
     * @param {number} callId - Call ID from callWasmFunc
     * @param {number} bufferId - Target GPU buffer ID
     * @param {number} offset - Offset in buffer
     * @param {number} byteLen - Number of bytes to copy
     */
    writeBufferFromWasm(callId, bufferId, offset, byteLen) {
        const result = this.wasmCallResults.get(callId);
        if (!result) {
            console.error(`[GPU] writeBufferFromWasm: call result ${callId} not found`);
            return;
        }

        const wasm = this.wasmModules.get(result.moduleId);
        if (!wasm || !wasm.memory) {
            console.error(`[GPU] writeBufferFromWasm: WASM memory not available`);
            return;
        }

        const buffer = this.buffers.get(bufferId);
        if (!buffer) {
            console.error(`[GPU] writeBufferFromWasm: buffer ${bufferId} not found`);
            return;
        }

        // Read bytes from WASM linear memory
        const data = new Uint8Array(wasm.memory.buffer, result.ptr, byteLen);

        console.log(`[GPU] writeBufferFromWasm(${callId}): ${byteLen} bytes → buffer ${bufferId} @ ${offset}`);

        // Write to GPU buffer
        this.device.queue.writeBuffer(buffer, offset, data);
    }

    /**
     * Resolve encoded WASM arguments to JavaScript values.
     *
     * Argument encoding format:
     * - [arg_count:u8][arg_type:u8, value?:4 bytes]...
     *
     * Arg types:
     * - 0x00: literal f32 (4 byte value follows)
     * - 0x01: $canvas.width (no value)
     * - 0x02: $canvas.height (no value)
     * - 0x03: $t.total (no value)
     * - 0x04: literal i32 (4 byte value follows)
     * - 0x05: literal u32 (4 byte value follows)
     * - 0x06: $t.delta (no value)
     *
     * @param {Uint8Array} encoded - Encoded arguments
     * @returns {number[]} Resolved argument values
     */
    resolveWasmArgs(encoded) {
        if (encoded.length === 0) return [];

        const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);
        const argCount = encoded[0];
        const resolved = [];
        let offset = 1;

        for (let i = 0; i < argCount && offset < encoded.length; i++) {
            const argType = encoded[offset++];

            switch (argType) {
                case 0x00: // literal_f32
                    if (offset + 4 <= encoded.length) {
                        resolved.push(view.getFloat32(offset, true));
                        offset += 4;
                    }
                    break;

                case 0x01: // canvas_width
                    resolved.push(this.context.canvas.width);
                    break;

                case 0x02: // canvas_height
                    resolved.push(this.context.canvas.height);
                    break;

                case 0x03: // time_total
                    resolved.push(this.currentTime);
                    break;

                case 0x04: // literal_i32
                    if (offset + 4 <= encoded.length) {
                        resolved.push(view.getInt32(offset, true));
                        offset += 4;
                    }
                    break;

                case 0x05: // literal_u32
                    if (offset + 4 <= encoded.length) {
                        resolved.push(view.getUint32(offset, true));
                        offset += 4;
                    }
                    break;

                case 0x06: // time_delta
                    resolved.push(this.deltaTime);
                    break;

                default:
                    console.warn(`[GPU] Unknown WASM arg type: 0x${argType.toString(16)}`);
                    break;
            }
        }

        return resolved;
    }

    /**
     * Copy an ImageBitmap to a GPU texture.
     * Uses WebGPU's copyExternalImageToTexture queue operation.
     * @param {number} bitmapId - ImageBitmap ID
     * @param {number} textureId - Destination texture ID
     * @param {number} mipLevel - Mip level (usually 0)
     * @param {number} originX - X origin in texture
     * @param {number} originY - Y origin in texture
     */
    async copyExternalImageToTexture(bitmapId, textureId, mipLevel, originX, originY) {
        console.log(`[GPU] copyExternalImageToTexture(bitmap=${bitmapId}, texture=${textureId}, mip=${mipLevel}, origin=[${originX},${originY}])`);

        // Get the ImageBitmap (may need to await promise)
        let bitmap = this.imageBitmaps.get(bitmapId);
        if (!bitmap) {
            console.error(`[GPU] ImageBitmap ${bitmapId} not found`);
            return;
        }

        // If it's a promise, await it
        if (bitmap instanceof Promise) {
            bitmap = await bitmap;
            this.imageBitmaps.set(bitmapId, bitmap);  // Cache resolved bitmap
        }

        const texture = this.textures.get(textureId);
        if (!texture) {
            console.error(`[GPU] Texture ${textureId} not found`);
            return;
        }

        // Copy ImageBitmap to texture
        this.device.queue.copyExternalImageToTexture(
            { source: bitmap },
            { texture, mipLevel, origin: { x: originX, y: originY } },
            { width: bitmap.width, height: bitmap.height }
        );

        console.log(`[GPU]   copied ${bitmap.width}x${bitmap.height} to texture ${textureId}`);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /**
     * Begin a render pass.
     * @param {number} textureId - Color attachment texture (0 = canvas)
     * @param {number} loadOp - Load operation (0=load, 1=clear)
     * @param {number} storeOp - Store operation (0=store, 1=discard)
     * @param {number} depthTextureId - Depth attachment texture (0xFFFF = none)
     */
    beginRenderPass(textureId, loadOp, storeOp, depthTextureId) {
        console.log(`[GPU] beginRenderPass(texture=${textureId}, load=${loadOp}, store=${storeOp}, depth=${depthTextureId})`);
        this.commandEncoder = this.device.createCommandEncoder();

        // Get render target (0 = current canvas texture)
        let view;
        if (textureId === 0) {
            view = this.context.getCurrentTexture().createView();
        } else {
            // TODO: Support custom render targets
            view = this.context.getCurrentTexture().createView();
        }

        const passDesc = {
            colorAttachments: [{
                view,
                loadOp: loadOp === 1 ? 'clear' : 'load',
                storeOp: storeOp === 0 ? 'store' : 'discard',
                clearValue: { r: 0.5, g: 0.5, b: 0.5, a: 1 },  // Gray background
            }],
        };

        // Add depth attachment if specified (0xFFFF = no depth)
        if (depthTextureId !== 0xFFFF && depthTextureId !== 65535) {
            const depthTexture = this.textures.get(depthTextureId);
            if (depthTexture) {
                passDesc.depthStencilAttachment = {
                    view: depthTexture.createView(),
                    depthClearValue: 1.0,
                    depthLoadOp: 'clear',
                    depthStoreOp: 'store',
                };
                console.log(`[GPU]   depth attachment: texture ${depthTextureId}`);
            } else {
                console.warn(`[GPU] Depth texture ${depthTextureId} not found`);
            }
        }

        this.currentPass = this.commandEncoder.beginRenderPass(passDesc);
        this.passType = 'render';
    }

    /**
     * Begin a compute pass.
     */
    beginComputePass() {
        this.commandEncoder = this.device.createCommandEncoder();
        this.currentPass = this.commandEncoder.beginComputePass();
        this.passType = 'compute';
    }

    /**
     * Set the current pipeline.
     * @param {number} id - Pipeline ID
     */
    setPipeline(id) {
        const pipeline = this.pipelines.get(id);
        console.log(`[GPU] setPipeline(${id}): ${pipeline ? 'found' : 'NOT FOUND'}, currentPass: ${this.currentPass ? 'active' : 'null'}`);
        if (!pipeline) {
            console.error(`[GPU] Pipeline ${id} not found! Available: ${[...this.pipelines.keys()].join(', ')}`);
        }
        if (!this.currentPass) {
            console.error(`[GPU] No active pass for setPipeline!`);
        }
        this.currentPass.setPipeline(pipeline);
    }

    /**
     * Set a bind group.
     * @param {number} slot - Bind group slot
     * @param {number} id - Bind group ID
     */
    setBindGroup(slot, id) {
        console.log(`[GPU] setBindGroup(slot=${slot}, id=${id})`);
        const bindGroup = this.bindGroups.get(id);
        this.currentPass.setBindGroup(slot, bindGroup);
    }

    /**
     * Set a vertex buffer.
     * @param {number} slot - Vertex buffer slot
     * @param {number} id - Buffer ID
     */
    setVertexBuffer(slot, id) {
        console.log(`[GPU] setVertexBuffer(slot=${slot}, id=${id})`);
        const buffer = this.buffers.get(id);
        this.currentPass.setVertexBuffer(slot, buffer);
    }

    /**
     * Draw primitives.
     * @param {number} vertexCount - Number of vertices
     * @param {number} instanceCount - Number of instances
     */
    draw(vertexCount, instanceCount) {
        console.log(`[GPU] draw(${vertexCount}, ${instanceCount})`);
        this.currentPass.draw(vertexCount, instanceCount);
    }

    /**
     * Draw indexed primitives.
     * @param {number} indexCount - Number of indices
     * @param {number} instanceCount - Number of instances
     */
    drawIndexed(indexCount, instanceCount) {
        this.currentPass.drawIndexed(indexCount, instanceCount);
    }

    /**
     * Dispatch compute workgroups.
     * @param {number} x - Workgroups in X
     * @param {number} y - Workgroups in Y
     * @param {number} z - Workgroups in Z
     */
    dispatch(x, y, z) {
        this.currentPass.dispatchWorkgroups(x, y, z);
    }

    /**
     * End the current pass.
     */
    endPass() {
        console.log(`[GPU] endPass()`);
        this.currentPass.end();
        this.currentPass = null;
        this.passType = null;
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    /**
     * Write data to a buffer.
     * @param {number} bufferId - Buffer ID
     * @param {number} offset - Byte offset
     * @param {number} dataPtr - Pointer to data
     * @param {number} dataLen - Data length
     */
    writeBuffer(bufferId, offset, dataPtr, dataLen) {
        const buffer = this.buffers.get(bufferId);
        const data = this.readBytes(dataPtr, dataLen);
        this.device.queue.writeBuffer(buffer, offset, data);
    }

    /**
     * Write uniform data directly to a buffer (called from JS, not WASM).
     * Used by the Play feature to update uniform buffers each frame.
     * @param {number} bufferId - Buffer ID
     * @param {Uint8Array} data - Data to write (12 bytes: f32 time + u32 width + u32 height)
     */
    writeTimeToBuffer(bufferId, data) {
        const buffer = this.buffers.get(bufferId);
        if (!buffer) {
            console.warn(`[GPU] writeTimeToBuffer: buffer ${bufferId} not found`);
            return;
        }
        // Log first frame only to avoid spam
        if (!this._uniformLogged) {
            const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
            const time = view.getFloat32(0, true);
            const width = view.getUint32(4, true);
            const height = view.getUint32(8, true);
            console.log(`[GPU] writeTimeToBuffer(${bufferId}): time=${time.toFixed(3)}, width=${width}, height=${height}`);
            this._uniformLogged = true;
        }
        this.device.queue.writeBuffer(buffer, 0, data);
    }

    /**
     * Submit command buffer to queue.
     */
    submit() {
        console.log(`[GPU] submit() - commandEncoder: ${this.commandEncoder ? 'present' : 'null'}`);
        if (this.commandEncoder) {
            const commandBuffer = this.commandEncoder.finish();
            this.device.queue.submit([commandBuffer]);
            this.commandEncoder = null;
        }
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /**
     * Map PNGine buffer usage flags to WebGPU usage flags.
     * @param {number} usage - PNGine usage flags (packed struct from Zig)
     * @returns {number} WebGPU usage flags
     *
     * Zig BufferUsage packed struct bit layout (LSB first):
     *   bit 0: map_read
     *   bit 1: map_write
     *   bit 2: copy_src
     *   bit 3: copy_dst
     *   bit 4: index
     *   bit 5: vertex
     *   bit 6: uniform
     *   bit 7: storage
     */
    mapBufferUsage(usage) {
        let gpuUsage = 0;

        // PNGine usage flags (matching Zig BufferUsage packed struct)
        const MAP_READ  = 0x01;  // bit 0
        const MAP_WRITE = 0x02;  // bit 1
        const COPY_SRC  = 0x04;  // bit 2
        const COPY_DST  = 0x08;  // bit 3
        const INDEX     = 0x10;  // bit 4
        const VERTEX    = 0x20;  // bit 5
        const UNIFORM   = 0x40;  // bit 6
        const STORAGE   = 0x80;  // bit 7

        if (usage & MAP_READ) gpuUsage |= GPUBufferUsage.MAP_READ;
        if (usage & MAP_WRITE) gpuUsage |= GPUBufferUsage.MAP_WRITE;
        if (usage & COPY_SRC) gpuUsage |= GPUBufferUsage.COPY_SRC;
        if (usage & COPY_DST) gpuUsage |= GPUBufferUsage.COPY_DST;
        if (usage & INDEX) gpuUsage |= GPUBufferUsage.INDEX;
        if (usage & VERTEX) gpuUsage |= GPUBufferUsage.VERTEX;
        if (usage & UNIFORM) gpuUsage |= GPUBufferUsage.UNIFORM;
        if (usage & STORAGE) gpuUsage |= GPUBufferUsage.STORAGE;

        return gpuUsage;
    }

    // ========================================================================
    // Binary Descriptor Decoders
    // ========================================================================

    /**
     * Decode a binary texture descriptor.
     * Format: type_tag(u8) + field_count(u8) + fields...
     * @param {Uint8Array} bytes - Binary descriptor data
     * @returns {GPUTextureDescriptor}
     */
    decodeTextureDescriptor(bytes) {
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        let offset = 0;

        // Validate type tag
        const typeTag = bytes[offset++];
        if (typeTag !== 0x01) { // DescriptorType.texture
            throw new Error(`Invalid texture descriptor type tag: ${typeTag}`);
        }

        const fieldCount = bytes[offset++];
        const desc = {
            size: [this.context.canvas.width, this.context.canvas.height],
            format: navigator.gpu.getPreferredCanvasFormat(),
            usage: GPUTextureUsage.RENDER_ATTACHMENT,
            sampleCount: 1,
        };

        // Field IDs (from DescriptorEncoder.TextureField)
        const FIELD_WIDTH = 0x01;
        const FIELD_HEIGHT = 0x02;
        const FIELD_SAMPLE_COUNT = 0x05;
        const FIELD_FORMAT = 0x07;
        const FIELD_USAGE = 0x08;

        // Value types
        const VALUE_U32 = 0x00;
        const VALUE_ENUM = 0x07;

        for (let i = 0; i < fieldCount; i++) {
            const fieldId = bytes[offset++];
            const valueType = bytes[offset++];

            if (valueType === VALUE_U32) {
                const value = view.getUint32(offset, true); // little endian
                offset += 4;

                if (fieldId === FIELD_WIDTH) desc.size[0] = value;
                else if (fieldId === FIELD_HEIGHT) desc.size[1] = value;
                else if (fieldId === FIELD_SAMPLE_COUNT) desc.sampleCount = value;
            } else if (valueType === VALUE_ENUM) {
                const value = bytes[offset++];

                if (fieldId === FIELD_FORMAT) {
                    desc.format = this.decodeTextureFormat(value);
                } else if (fieldId === FIELD_USAGE) {
                    desc.usage = this.decodeTextureUsage(value);
                }
            }
        }

        return desc;
    }

    /**
     * Decode a binary sampler descriptor.
     * @param {Uint8Array} bytes - Binary descriptor data
     * @returns {GPUSamplerDescriptor}
     */
    decodeSamplerDescriptor(bytes) {
        let offset = 0;

        // Validate type tag
        const typeTag = bytes[offset++];
        if (typeTag !== 0x02) { // DescriptorType.sampler
            throw new Error(`Invalid sampler descriptor type tag: ${typeTag}`);
        }

        const fieldCount = bytes[offset++];
        const desc = {
            magFilter: 'linear',
            minFilter: 'linear',
            addressModeU: 'clamp-to-edge',
            addressModeV: 'clamp-to-edge',
        };

        // Field IDs (from DescriptorEncoder.SamplerField)
        const FIELD_ADDRESS_MODE_U = 0x01;
        const FIELD_ADDRESS_MODE_V = 0x02;
        const FIELD_MAG_FILTER = 0x04;
        const FIELD_MIN_FILTER = 0x05;

        // Value type for enum
        const VALUE_ENUM = 0x07;

        for (let i = 0; i < fieldCount; i++) {
            const fieldId = bytes[offset++];
            const valueType = bytes[offset++];

            if (valueType === VALUE_ENUM) {
                const value = bytes[offset++];

                if (fieldId === FIELD_MAG_FILTER) {
                    desc.magFilter = this.decodeFilterMode(value);
                } else if (fieldId === FIELD_MIN_FILTER) {
                    desc.minFilter = this.decodeFilterMode(value);
                } else if (fieldId === FIELD_ADDRESS_MODE_U) {
                    desc.addressModeU = this.decodeAddressMode(value);
                } else if (fieldId === FIELD_ADDRESS_MODE_V) {
                    desc.addressModeV = this.decodeAddressMode(value);
                }
            }
        }

        return desc;
    }

    /**
     * Decode texture format enum.
     * @param {number} value - Format enum value
     * @returns {string} WebGPU format string
     */
    decodeTextureFormat(value) {
        const formats = {
            0x00: 'rgba8unorm',
            0x01: 'rgba8snorm',
            0x02: 'rgba8uint',
            0x03: 'rgba8sint',
            0x04: 'bgra8unorm',
            0x05: 'rgba16float',
            0x06: 'rgba32float',
            0x10: 'depth24plus',
            0x11: 'depth24plus-stencil8',
            0x12: 'depth32float',
        };
        return formats[value] || navigator.gpu.getPreferredCanvasFormat();
    }

    /**
     * Decode texture usage flags.
     * @param {number} value - Usage flags packed as u8
     * @returns {number} WebGPU usage flags
     */
    decodeTextureUsage(value) {
        let usage = 0;
        if (value & 0x01) usage |= GPUTextureUsage.COPY_SRC;
        if (value & 0x02) usage |= GPUTextureUsage.COPY_DST;
        if (value & 0x04) usage |= GPUTextureUsage.TEXTURE_BINDING;
        if (value & 0x08) usage |= GPUTextureUsage.STORAGE_BINDING;
        if (value & 0x10) usage |= GPUTextureUsage.RENDER_ATTACHMENT;
        return usage || GPUTextureUsage.RENDER_ATTACHMENT; // Default
    }

    /**
     * Decode filter mode enum.
     * @param {number} value - Filter mode value
     * @returns {string} WebGPU filter mode
     */
    decodeFilterMode(value) {
        return value === 0 ? 'nearest' : 'linear';
    }

    /**
     * Decode address mode enum.
     * @param {number} value - Address mode value
     * @returns {string} WebGPU address mode
     */
    decodeAddressMode(value) {
        const modes = ['clamp-to-edge', 'repeat', 'mirror-repeat'];
        return modes[value] || 'clamp-to-edge';
    }

    /**
     * Decode a binary bind group descriptor.
     * Format: type_tag(u8) + field_count(u8) + fields...
     * @param {Uint8Array} bytes - Binary descriptor data
     * @returns {{groupIndex: number, entries: Array}}
     */
    decodeBindGroupDescriptor(bytes) {
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        let offset = 0;

        // Validate type tag
        const typeTag = bytes[offset++];
        if (typeTag !== 0x03) { // DescriptorType.bind_group
            throw new Error(`Invalid bind group descriptor type tag: ${typeTag}`);
        }

        const fieldCount = bytes[offset++];
        let groupIndex = 0;
        const entries = [];

        // Field IDs (from DescriptorEncoder.BindGroupField)
        const FIELD_LAYOUT = 0x01;
        const FIELD_ENTRIES = 0x02;

        // Value types
        const VALUE_ARRAY = 0x03;
        const VALUE_ENUM = 0x07;

        for (let i = 0; i < fieldCount; i++) {
            const fieldId = bytes[offset++];
            const valueType = bytes[offset++];

            if (fieldId === FIELD_LAYOUT && valueType === VALUE_ENUM) {
                groupIndex = bytes[offset++];
            } else if (fieldId === FIELD_ENTRIES && valueType === VALUE_ARRAY) {
                const entryCount = bytes[offset++];

                for (let j = 0; j < entryCount; j++) {
                    const binding = bytes[offset++];
                    const resourceType = bytes[offset++];
                    const resourceId = view.getUint16(offset, true); // little endian
                    offset += 2;

                    const entry = { binding, resourceType, resourceId };

                    // Buffer bindings have additional offset/size fields
                    if (resourceType === 0) { // buffer
                        entry.offset = view.getUint32(offset, true);
                        offset += 4;
                        entry.size = view.getUint32(offset, true);
                        offset += 4;
                    }

                    entries.push(entry);
                }
            }
        }

        return { groupIndex, entries };
    }

    /**
     * Get WASM imports object for instantiation.
     * @returns {Object} Imports object
     */
    getImports() {
        console.log('[PNGineGPU] Creating WASM imports object');
        const self = this;
        return {
            env: {
                gpuCreateBuffer: (id, size, usage) => self.createBuffer(id, size, usage),
                gpuCreateTexture: (id, ptr, len) => self.createTexture(id, ptr, len),
                gpuCreateSampler: (id, ptr, len) => self.createSampler(id, ptr, len),
                gpuCreateShaderModule: (id, ptr, len) => self.createShaderModule(id, ptr, len),
                gpuCreateRenderPipeline: (id, ptr, len) => self.createRenderPipeline(id, ptr, len),
                gpuCreateComputePipeline: (id, ptr, len) => self.createComputePipeline(id, ptr, len),
                gpuCreateBindGroup: (id, layout, ptr, len) => self.createBindGroup(id, layout, ptr, len),
                gpuCreateImageBitmap: (id, ptr, len) => self.createImageBitmap(id, ptr, len),
                gpuBeginRenderPass: (tex, load, store, depth) => self.beginRenderPass(tex, load, store, depth),
                gpuBeginComputePass: () => self.beginComputePass(),
                gpuSetPipeline: (id) => {
                    console.log(`[WASM->JS] gpuSetPipeline called with id=${id}`);
                    self.setPipeline(id);
                },
                gpuSetBindGroup: (slot, id) => {
                    console.log(`[WASM->JS] gpuSetBindGroup called with slot=${slot}, id=${id}`);
                    self.setBindGroup(slot, id);
                },
                gpuSetVertexBuffer: (slot, id) => {
                    console.log(`[WASM->JS] gpuSetVertexBuffer called with slot=${slot}, id=${id}`);
                    self.setVertexBuffer(slot, id);
                },
                gpuDraw: (v, i) => {
                    console.log(`[WASM->JS] gpuDraw called with v=${v}, i=${i}`);
                    self.draw(v, i);
                },
                gpuDrawIndexed: (idx, i) => self.drawIndexed(idx, i),
                gpuDispatch: (x, y, z) => self.dispatch(x, y, z),
                gpuEndPass: () => self.endPass(),
                gpuWriteBuffer: (id, off, ptr, len) => self.writeBuffer(id, off, ptr, len),
                gpuSubmit: () => self.submit(),
                gpuCopyExternalImageToTexture: (bitmapId, textureId, mipLevel, originX, originY) =>
                    self.copyExternalImageToTexture(bitmapId, textureId, mipLevel, originX, originY),
                // WASM module operations
                gpuInitWasmModule: (moduleId, dataPtr, dataLen) =>
                    self.initWasmModule(moduleId, dataPtr, dataLen),
                gpuCallWasmFunc: (callId, moduleId, funcNamePtr, funcNameLen, argsPtr, argsLen) =>
                    self.callWasmFunc(callId, moduleId, funcNamePtr, funcNameLen, argsPtr, argsLen),
                gpuWriteBufferFromWasm: (callId, bufferId, offset, byteLen) =>
                    self.writeBufferFromWasm(callId, bufferId, offset, byteLen),
            },
        };
    }

    /**
     * Reset all state (for reloading).
     */
    reset() {
        // Destroy GPU resources
        for (const buffer of this.buffers.values()) {
            buffer.destroy();
        }
        for (const texture of this.textures.values()) {
            texture.destroy();
        }

        this.buffers.clear();
        this.bufferMeta.clear();
        this.textures.clear();
        this.samplers.clear();
        this.shaders.clear();
        this.pipelines.clear();
        this.bindGroups.clear();
        this.imageBitmaps.clear();
        this.wasmModules.clear();
        this.wasmCallResults.clear();
        this.commandEncoder = null;
        this.currentPass = null;
        this.passType = null;
        this.currentTime = 0;
        this.deltaTime = 0;
    }
}
