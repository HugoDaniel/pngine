/**
 * PNGine WebGPU Backend
 *
 * Implements the GPU operations called by the WASM module.
 * Manages WebGPU resources and translates WASM calls to actual GPU operations.
 */

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
        this.shaders = new Map();
        this.pipelines = new Map();
        this.bindGroups = new Map();

        // Render state
        this.commandEncoder = null;
        this.currentPass = null;
        this.passType = null; // 'render' | 'compute'
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
     * @param {number} id - Buffer ID
     * @param {number} size - Buffer size in bytes
     * @param {number} usage - Usage flags
     */
    createBuffer(id, size, usage) {
        const buffer = this.device.createBuffer({
            size,
            usage: this.mapBufferUsage(usage),
        });
        this.buffers.set(id, buffer);
    }

    /**
     * Create a shader module from WGSL code.
     * @param {number} id - Shader ID
     * @param {number} codePtr - Pointer to WGSL code
     * @param {number} codeLen - Code length
     */
    createShaderModule(id, codePtr, codeLen) {
        const code = this.readString(codePtr, codeLen);
        const module = this.device.createShaderModule({ code });
        this.shaders.set(id, module);
    }

    /**
     * Create a render pipeline.
     * @param {number} id - Pipeline ID
     * @param {number} descPtr - Pointer to descriptor JSON
     * @param {number} descLen - Descriptor length
     */
    createRenderPipeline(id, descPtr, descLen) {
        const descJson = this.readString(descPtr, descLen);
        const desc = JSON.parse(descJson);

        // Resolve shader module references
        const pipelineDesc = {
            layout: 'auto',
            vertex: {
                module: this.shaders.get(desc.vertex.shader),
                entryPoint: desc.vertex.entryPoint || 'vertexMain',
            },
            primitive: {
                topology: desc.primitive?.topology || 'triangle-list',
            },
        };

        if (desc.fragment) {
            pipelineDesc.fragment = {
                module: this.shaders.get(desc.fragment.shader),
                entryPoint: desc.fragment.entryPoint || 'fragmentMain',
                targets: [{
                    format: navigator.gpu.getPreferredCanvasFormat(),
                }],
            };
        }

        const pipeline = this.device.createRenderPipeline(pipelineDesc);
        this.pipelines.set(id, pipeline);
    }

    /**
     * Create a compute pipeline.
     * @param {number} id - Pipeline ID
     * @param {number} descPtr - Pointer to descriptor JSON
     * @param {number} descLen - Descriptor length
     */
    createComputePipeline(id, descPtr, descLen) {
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
     * @param {number} id - Bind group ID
     * @param {number} layoutId - Layout ID (unused with 'auto' layout)
     * @param {number} entriesPtr - Pointer to entries JSON
     * @param {number} entriesLen - Entries length
     */
    createBindGroup(id, layoutId, entriesPtr, entriesLen) {
        const entriesJson = this.readString(entriesPtr, entriesLen);
        const desc = JSON.parse(entriesJson);

        // Resolve resource references in entries
        const entries = desc.entries.map(entry => {
            const resolved = { binding: entry.binding };
            if (entry.buffer !== undefined) {
                resolved.resource = { buffer: this.buffers.get(entry.buffer) };
            }
            return resolved;
        });

        // Get layout from pipeline
        const pipeline = this.pipelines.get(desc.pipeline);
        const bindGroup = this.device.createBindGroup({
            layout: pipeline.getBindGroupLayout(desc.group || 0),
            entries,
        });
        this.bindGroups.set(id, bindGroup);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /**
     * Begin a render pass.
     * @param {number} textureId - Color attachment texture (0 = canvas)
     * @param {number} loadOp - Load operation (0=load, 1=clear)
     * @param {number} storeOp - Store operation (0=store, 1=discard)
     */
    beginRenderPass(textureId, loadOp, storeOp) {
        this.commandEncoder = this.device.createCommandEncoder();

        // Get render target (0 = current canvas texture)
        let view;
        if (textureId === 0) {
            view = this.context.getCurrentTexture().createView();
        } else {
            // TODO: Support custom render targets
            view = this.context.getCurrentTexture().createView();
        }

        this.currentPass = this.commandEncoder.beginRenderPass({
            colorAttachments: [{
                view,
                loadOp: loadOp === 1 ? 'clear' : 'load',
                storeOp: storeOp === 0 ? 'store' : 'discard',
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
            }],
        });
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
        this.currentPass.setPipeline(pipeline);
    }

    /**
     * Set a bind group.
     * @param {number} slot - Bind group slot
     * @param {number} id - Bind group ID
     */
    setBindGroup(slot, id) {
        const bindGroup = this.bindGroups.get(id);
        this.currentPass.setBindGroup(slot, bindGroup);
    }

    /**
     * Set a vertex buffer.
     * @param {number} slot - Vertex buffer slot
     * @param {number} id - Buffer ID
     */
    setVertexBuffer(slot, id) {
        const buffer = this.buffers.get(id);
        this.currentPass.setVertexBuffer(slot, buffer);
    }

    /**
     * Draw primitives.
     * @param {number} vertexCount - Number of vertices
     * @param {number} instanceCount - Number of instances
     */
    draw(vertexCount, instanceCount) {
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
     * Submit command buffer to queue.
     */
    submit() {
        if (this.commandEncoder) {
            this.device.queue.submit([this.commandEncoder.finish()]);
            this.commandEncoder = null;
        }
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /**
     * Map PNGine buffer usage flags to WebGPU usage flags.
     * @param {number} usage - PNGine usage flags
     * @returns {number} WebGPU usage flags
     */
    mapBufferUsage(usage) {
        let gpuUsage = 0;

        // PNGine usage flags (matching bytecode format)
        const VERTEX = 0x01;
        const INDEX = 0x02;
        const UNIFORM = 0x04;
        const STORAGE = 0x08;
        const COPY_SRC = 0x10;
        const COPY_DST = 0x20;

        if (usage & VERTEX) gpuUsage |= GPUBufferUsage.VERTEX;
        if (usage & INDEX) gpuUsage |= GPUBufferUsage.INDEX;
        if (usage & UNIFORM) gpuUsage |= GPUBufferUsage.UNIFORM;
        if (usage & STORAGE) gpuUsage |= GPUBufferUsage.STORAGE;
        if (usage & COPY_SRC) gpuUsage |= GPUBufferUsage.COPY_SRC;
        if (usage & COPY_DST) gpuUsage |= GPUBufferUsage.COPY_DST;

        return gpuUsage;
    }

    /**
     * Get WASM imports object for instantiation.
     * @returns {Object} Imports object
     */
    getImports() {
        return {
            env: {
                gpuCreateBuffer: (id, size, usage) => this.createBuffer(id, size, usage),
                gpuCreateShaderModule: (id, ptr, len) => this.createShaderModule(id, ptr, len),
                gpuCreateRenderPipeline: (id, ptr, len) => this.createRenderPipeline(id, ptr, len),
                gpuCreateComputePipeline: (id, ptr, len) => this.createComputePipeline(id, ptr, len),
                gpuCreateBindGroup: (id, layout, ptr, len) => this.createBindGroup(id, layout, ptr, len),
                gpuBeginRenderPass: (tex, load, store) => this.beginRenderPass(tex, load, store),
                gpuBeginComputePass: () => this.beginComputePass(),
                gpuSetPipeline: (id) => this.setPipeline(id),
                gpuSetBindGroup: (slot, id) => this.setBindGroup(slot, id),
                gpuSetVertexBuffer: (slot, id) => this.setVertexBuffer(slot, id),
                gpuDraw: (v, i) => this.draw(v, i),
                gpuDrawIndexed: (idx, i) => this.drawIndexed(idx, i),
                gpuDispatch: (x, y, z) => this.dispatch(x, y, z),
                gpuEndPass: () => this.endPass(),
                gpuWriteBuffer: (id, off, ptr, len) => this.writeBuffer(id, off, ptr, len),
                gpuSubmit: () => this.submit(),
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

        this.buffers.clear();
        this.shaders.clear();
        this.pipelines.clear();
        this.bindGroups.clear();
        this.commandEncoder = null;
        this.currentPass = null;
        this.passType = null;
    }
}
