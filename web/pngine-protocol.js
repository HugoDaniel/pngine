/**
 * PNGine Worker Protocol
 *
 * Shared message type definitions for main thread <-> Worker communication.
 */

/**
 * Message types for Worker RPC.
 */
export const MessageType = {
    // Lifecycle
    INIT: 'init',
    TERMINATE: 'terminate',

    // Compilation
    COMPILE: 'compile',

    // Module management
    LOAD_MODULE: 'loadModule',
    LOAD_FROM_URL: 'loadFromUrl',
    FREE_MODULE: 'freeModule',

    // Execution
    EXECUTE_ALL: 'executeAll',
    EXECUTE_FRAME: 'executeFrame',
    RENDER_FRAME: 'renderFrame',

    // Query
    GET_FRAME_COUNT: 'getFrameCount',
    GET_METADATA: 'getMetadata',
    FIND_UNIFORM_BUFFER: 'findUniformBuffer',

    // Response types
    RESPONSE: 'response',
    ERROR: 'error',
};

/**
 * Error codes returned by WASM functions.
 */
export const ErrorCode = {
    SUCCESS: 0,
    NOT_INITIALIZED: 1,
    OUT_OF_MEMORY: 2,
    PARSE_ERROR: 3,
    INVALID_FORMAT: 4,
    NO_MODULE: 5,
    EXECUTION_ERROR: 6,
    // Assembler errors (10-29)
    UNKNOWN_FORM: 10,
    INVALID_FORM_STRUCTURE: 11,
    UNDEFINED_RESOURCE: 12,
    DUPLICATE_RESOURCE: 13,
    TOO_MANY_RESOURCES: 14,
    EXPECTED_ATOM: 15,
    EXPECTED_STRING: 16,
    EXPECTED_NUMBER: 17,
    EXPECTED_LIST: 18,
    INVALID_RESOURCE_ID: 19,
    UNKNOWN: 99,
};

/**
 * Get human-readable error message.
 * @param {number} code - Error code
 * @returns {string} Error message
 */
export function getErrorMessage(code) {
    switch (code) {
        case ErrorCode.NOT_INITIALIZED: return 'WASM not initialized';
        case ErrorCode.OUT_OF_MEMORY: return 'Out of memory';
        case ErrorCode.PARSE_ERROR: return 'Parse error';
        case ErrorCode.INVALID_FORMAT: return 'Invalid bytecode format';
        case ErrorCode.NO_MODULE: return 'No module loaded';
        case ErrorCode.EXECUTION_ERROR: return 'Execution error';
        case ErrorCode.UNKNOWN_FORM: return 'Unknown PBSF form';
        case ErrorCode.INVALID_FORM_STRUCTURE: return 'Invalid form structure';
        case ErrorCode.UNDEFINED_RESOURCE: return 'Undefined resource reference';
        case ErrorCode.DUPLICATE_RESOURCE: return 'Duplicate resource ID';
        case ErrorCode.TOO_MANY_RESOURCES: return 'Too many resources';
        case ErrorCode.EXPECTED_ATOM: return 'Expected atom';
        case ErrorCode.EXPECTED_STRING: return 'Expected string';
        case ErrorCode.EXPECTED_NUMBER: return 'Expected number';
        case ErrorCode.EXPECTED_LIST: return 'Expected list';
        case ErrorCode.INVALID_RESOURCE_ID: return 'Invalid resource ID format';
        default: return `Unknown error (${code})`;
    }
}
