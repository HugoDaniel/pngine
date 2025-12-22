/**
 * PNGine - WebGPU bytecode engine
 *
 * Shader art that fits in a PNG file, executable in any browser.
 */

// ============================================================================
// Initialization Options
// ============================================================================

/**
 * Options for initializing PNGine.
 */
export interface InitOptions {
  /**
   * URL to the pngine.wasm file.
   * @default Bundled WASM path
   */
  wasmUrl?: string;
}

// ============================================================================
// Initialization Functions
// ============================================================================

/**
 * Initialize PNGine with a canvas element.
 *
 * All GPU operations run in a WebWorker with OffscreenCanvas.
 *
 * @param canvas - HTML canvas element for rendering
 * @param options - Initialization options
 * @returns Promise resolving to a PNGine instance
 *
 * @example
 * ```javascript
 * const canvas = document.getElementById('canvas');
 * const pngine = await initPNGine(canvas);
 * await pngine.loadFromUrl('shader.png');
 * pngine.startAnimation();
 * ```
 */
export function initPNGine(
  canvas: HTMLCanvasElement,
  options?: InitOptions
): Promise<PNGine>;

/**
 * Initialize PNGine and load a module from a URL.
 *
 * Convenience function that combines initPNGine() and loadFromUrl().
 * Auto-detects format (PNG, ZIP, or raw PNGB).
 *
 * @param canvas - HTML canvas element for rendering
 * @param url - URL to PNG, ZIP, or PNGB file
 * @param options - Initialization options
 * @returns Promise resolving to a PNGine instance with loaded module
 */
export function initFromUrl(
  canvas: HTMLCanvasElement,
  url: string,
  options?: InitOptions
): Promise<PNGine>;

/**
 * Initialize PNGine and load a module from a PNG file.
 *
 * @param canvas - HTML canvas element for rendering
 * @param pngUrl - URL to PNG file with embedded bytecode
 * @param options - Initialization options
 * @returns Promise resolving to a PNGine instance with loaded module
 */
export function initFromPng(
  canvas: HTMLCanvasElement,
  pngUrl: string,
  options?: InitOptions
): Promise<PNGine>;

/**
 * Initialize PNGine and load a module from a ZIP bundle.
 *
 * @param canvas - HTML canvas element for rendering
 * @param zipUrl - URL to ZIP bundle
 * @param options - Initialization options
 * @returns Promise resolving to a PNGine instance with loaded module
 */
export function initFromZip(
  canvas: HTMLCanvasElement,
  zipUrl: string,
  options?: InitOptions
): Promise<PNGine>;

// ============================================================================
// PNGine Class
// ============================================================================

/**
 * Result of loading a module.
 */
export interface LoadResult {
  /** Number of frames in the loaded module */
  frameCount: number;
}

/**
 * Module metadata.
 */
export interface Metadata {
  /** Number of frames in the loaded module */
  frameCount: number;
  /** Canvas width in pixels */
  canvasWidth: number;
  /** Canvas height in pixels */
  canvasHeight: number;
}

/**
 * Information about a GPU buffer.
 */
export interface BufferInfo {
  /** Buffer resource ID */
  id: number;
  /** Buffer size in bytes */
  size: number;
}

/**
 * PNGine runtime instance.
 *
 * All GPU operations are executed in a WebWorker.
 * The animation loop runs on the main thread for precise timing.
 */
export class PNGine {
  /** Canvas width in pixels */
  readonly width: number;

  /** Canvas height in pixels */
  readonly height: number;

  /** Whether the animation loop is running */
  readonly isPlaying: boolean;

  /** Current animation time in seconds */
  readonly currentTime: number;

  /**
   * Name of the frame to render during animation.
   * Set to null to render all frames.
   */
  currentFrameName: string | null;

  /**
   * Callback invoked on each animation frame with the current time.
   * Useful for updating UI elements like sliders.
   */
  onTimeUpdate: ((time: number) => void) | null;

  // --------------------------------------------------------------------------
  // Compilation & Loading
  // --------------------------------------------------------------------------

  /**
   * Compile PNGine DSL source code to PNGB bytecode.
   *
   * @param source - DSL source code
   * @returns Promise resolving to compiled bytecode
   */
  compile(source: string): Promise<Uint8Array>;

  /**
   * Load compiled bytecode for execution.
   *
   * @param bytecode - PNGB bytecode
   * @returns Promise resolving to load result
   */
  loadModule(bytecode: Uint8Array): Promise<LoadResult>;

  /**
   * Load a module from a URL.
   *
   * Auto-detects format (PNG, ZIP, or raw PNGB).
   *
   * @param url - URL to the file
   * @returns Promise resolving to load result
   */
  loadFromUrl(url: string): Promise<LoadResult>;

  /**
   * Load a module from raw data.
   *
   * Auto-detects format (PNG, ZIP, or raw PNGB).
   *
   * @param data - File data
   * @returns Promise resolving to load result
   */
  loadFromData(data: ArrayBuffer | Uint8Array): Promise<LoadResult>;

  /**
   * Load a module from PNG data.
   *
   * @param pngData - PNG file data with embedded bytecode
   * @returns Promise resolving to load result
   */
  loadFromPngData(pngData: ArrayBuffer | Uint8Array): Promise<LoadResult>;

  /**
   * Load a module from ZIP data.
   *
   * @param zipData - ZIP bundle data
   * @returns Promise resolving to load result
   */
  loadFromZipData(zipData: ArrayBuffer | Uint8Array): Promise<LoadResult>;

  /**
   * Free the currently loaded module.
   *
   * @returns Promise resolving when complete
   */
  freeModule(): Promise<void>;

  // --------------------------------------------------------------------------
  // Execution
  // --------------------------------------------------------------------------

  /**
   * Compile and execute source code in one step.
   *
   * @param source - DSL source code
   * @returns Promise resolving when complete
   */
  run(source: string): Promise<void>;

  /**
   * Execute all bytecode in the loaded module.
   *
   * @returns Promise resolving when complete
   */
  executeAll(): Promise<void>;

  /**
   * Execute a specific frame by name.
   *
   * @param frameName - Name of the frame to execute
   * @returns Promise resolving when complete
   */
  executeFrameByName(frameName: string): Promise<void>;

  /**
   * Render a single frame at the specified time.
   *
   * Does not start the animation loop.
   *
   * @param time - Time in seconds
   * @param frameName - Optional frame name (null = all frames)
   * @returns Promise resolving when complete
   */
  renderFrame(time: number, frameName?: string | null): Promise<void>;

  // --------------------------------------------------------------------------
  // Animation
  // --------------------------------------------------------------------------

  /**
   * Start the animation loop.
   *
   * Renders frames continuously at display refresh rate.
   */
  startAnimation(): void;

  /**
   * Stop the animation loop.
   */
  stopAnimation(): void;

  /**
   * Set the frame to render during animation.
   *
   * @param frameName - Frame name, or null for all frames
   */
  setFrame(frameName: string | null): void;

  /**
   * Get the current animation time in seconds.
   *
   * @returns Current time
   */
  getTime(): number;

  // --------------------------------------------------------------------------
  // Metadata
  // --------------------------------------------------------------------------

  /**
   * Get the number of frames in the loaded module.
   *
   * @returns Promise resolving to frame count
   */
  getFrameCount(): Promise<number>;

  /**
   * Get metadata from the loaded module.
   *
   * @returns Promise resolving to metadata
   */
  getMetadata(): Promise<Metadata>;

  /**
   * Find the first buffer with UNIFORM usage.
   *
   * Used internally for time-based animation uniforms.
   *
   * @returns Promise resolving to buffer info or null
   */
  findUniformBuffer(): Promise<BufferInfo | null>;

  // --------------------------------------------------------------------------
  // Debug & Lifecycle
  // --------------------------------------------------------------------------

  /**
   * Enable or disable debug logging.
   *
   * @param enabled - Whether to enable debug logging
   * @returns Promise resolving when complete
   */
  setDebug(enabled: boolean): Promise<void>;

  /**
   * Terminate the WebWorker and release all resources.
   *
   * The PNGine instance cannot be used after calling this.
   */
  terminate(): void;
}

// ============================================================================
// Format Detection & Extraction
// ============================================================================

/**
 * Detect the format of file data.
 *
 * @param bytes - File data
 * @returns Detected format or null if unknown
 */
export function detectFormat(bytes: Uint8Array): 'png' | 'zip' | 'pngb' | null;

/**
 * Extract bytecode from any supported format.
 *
 * Auto-detects format (PNG, ZIP, or raw PNGB).
 *
 * @param data - File data
 * @returns Promise resolving to extracted bytecode
 */
export function extractBytecode(data: ArrayBuffer | Uint8Array): Promise<Uint8Array>;

/**
 * Fetch a file from URL and extract bytecode.
 *
 * Auto-detects format (PNG, ZIP, or raw PNGB).
 *
 * @param url - URL to fetch
 * @returns Promise resolving to extracted bytecode
 */
export function fetchBytecode(url: string): Promise<Uint8Array>;

// ============================================================================
// PNG Utilities
// ============================================================================

/**
 * Check if data contains a pNGb chunk (embedded bytecode).
 *
 * @param data - PNG file data
 * @returns True if pNGb chunk exists
 */
export function hasPngb(data: ArrayBuffer | Uint8Array): boolean;

/**
 * Get information about the pNGb chunk.
 *
 * @param data - PNG file data
 * @returns Chunk info or null if not present
 */
export function getPngbInfo(data: ArrayBuffer | Uint8Array): {
  version: number;
  compressed: boolean;
  payloadSize: number;
} | null;

/**
 * Extract bytecode from a PNG file.
 *
 * @param data - PNG file data
 * @returns Extracted bytecode
 * @throws If no pNGb chunk is found
 */
export function extractPngb(data: ArrayBuffer | Uint8Array): Uint8Array;

/**
 * Fetch a PNG file and extract bytecode.
 *
 * @param url - URL to PNG file
 * @returns Promise resolving to extracted bytecode
 */
export function fetchAndExtract(url: string): Promise<Uint8Array>;

/**
 * Check if data contains a pNGm chunk (animation metadata).
 *
 * @param data - PNG file data
 * @returns True if pNGm chunk exists
 */
export function hasPngm(data: ArrayBuffer | Uint8Array): boolean;

/**
 * Extract animation metadata from a PNG file.
 *
 * @param data - PNG file data
 * @returns Metadata object or null if not present
 */
export function extractPngm(data: ArrayBuffer | Uint8Array): object | null;

/**
 * Extract both bytecode and metadata from a PNG file.
 *
 * @param data - PNG file data
 * @returns Object with bytecode and optional metadata
 */
export function extractAll(data: ArrayBuffer | Uint8Array): Promise<{
  bytecode: Uint8Array;
  metadata: object | null;
}>;

// ============================================================================
// ZIP Utilities
// ============================================================================

/**
 * Check if data is a ZIP file.
 *
 * @param data - File data
 * @returns True if ZIP format
 */
export function isZip(data: ArrayBuffer | Uint8Array): boolean;

/**
 * Extract bytecode from a ZIP bundle.
 *
 * Looks for main.pngb or *.pngb in the archive.
 *
 * @param data - ZIP file data
 * @returns Extracted bytecode
 */
export function extractFromZip(data: ArrayBuffer | Uint8Array): Uint8Array;

/**
 * Fetch a ZIP bundle and extract bytecode.
 *
 * @param url - URL to ZIP file
 * @returns Promise resolving to extracted bytecode
 */
export function fetchAndExtractZip(url: string): Promise<Uint8Array>;

/**
 * Get information about a ZIP bundle.
 *
 * @param data - ZIP file data
 * @returns Bundle info
 */
export function getZipBundleInfo(data: ArrayBuffer | Uint8Array): Promise<{
  files: string[];
  manifest: object | null;
  hasRuntime: boolean;
}>;

/**
 * ZIP file reader for advanced access.
 */
export class ZipReader {
  constructor(data: ArrayBuffer | Uint8Array);

  /**
   * List all files in the archive.
   */
  list(): string[];

  /**
   * Check if a file exists in the archive.
   */
  has(filename: string): boolean;

  /**
   * Extract a specific file from the archive.
   */
  extract(filename: string): Promise<Uint8Array>;
}

// ============================================================================
// Debug
// ============================================================================

/**
 * Enable or disable global debug logging.
 *
 * Debug mode can also be enabled via:
 * - URL parameter: ?debug=true
 * - localStorage: pngine_debug=true
 *
 * @param enabled - Whether to enable debug logging
 */
export function setDebug(enabled: boolean): void;

/**
 * Check if debug mode is enabled.
 *
 * @returns True if debug mode is enabled
 */
export function isDebugEnabled(): boolean;

// ============================================================================
// Protocol (Advanced)
// ============================================================================

/**
 * Message types for Worker communication.
 *
 * For advanced usage only.
 */
export const MessageType: {
  readonly INIT: 'init';
  readonly TERMINATE: 'terminate';
  readonly COMPILE: 'compile';
  readonly LOAD_MODULE: 'loadModule';
  readonly LOAD_FROM_URL: 'loadFromUrl';
  readonly FREE_MODULE: 'freeModule';
  readonly EXECUTE_ALL: 'executeAll';
  readonly EXECUTE_FRAME: 'executeFrame';
  readonly RENDER_FRAME: 'renderFrame';
  readonly GET_FRAME_COUNT: 'getFrameCount';
  readonly GET_METADATA: 'getMetadata';
  readonly FIND_UNIFORM_BUFFER: 'findUniformBuffer';
  readonly SET_DEBUG: 'setDebug';
  readonly RESPONSE: 'response';
  readonly ERROR: 'error';
};

/**
 * Error codes returned by the WASM runtime.
 */
export const ErrorCode: {
  readonly SUCCESS: 0;
  readonly NOT_INITIALIZED: 1;
  readonly OUT_OF_MEMORY: 2;
  readonly PARSE_ERROR: 3;
  readonly INVALID_FORMAT: 4;
  readonly NO_MODULE: 5;
  readonly EXECUTION_ERROR: 6;
  readonly UNKNOWN_FORM: 10;
  readonly INVALID_FORM_STRUCTURE: 11;
  readonly UNDEFINED_RESOURCE: 12;
  readonly DUPLICATE_RESOURCE: 13;
  readonly TOO_MANY_RESOURCES: 14;
  readonly EXPECTED_ATOM: 15;
  readonly EXPECTED_STRING: 16;
  readonly EXPECTED_NUMBER: 17;
  readonly EXPECTED_LIST: 18;
  readonly INVALID_RESOURCE_ID: 19;
  readonly UNKNOWN: 99;
};

/**
 * Get a human-readable error message for an error code.
 *
 * @param code - Error code
 * @returns Error message
 */
export function getErrorMessage(code: number): string;
