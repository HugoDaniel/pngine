# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in PNGine, please report it
responsibly.

**Email**: security@hugodaniel.com

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

You should receive an acknowledgement within 48 hours. We will work with you
to understand and address the issue before any public disclosure.

## Scope

The following are in scope for security reports:

- **Compiler (Zig)**: Buffer overflows, memory safety issues in parsing or
  bytecode generation
- **WASM executor**: Sandbox escapes, unexpected memory access
- **Browser runtime** (the six published profiles — viewer, dev, core,
  executor, mini, mini-no-audio): XSS via crafted bytecode, prototype
  pollution, arbitrary code execution
- **PNG parsing**: Malformed PNG/PNGB payloads causing crashes or exploitable
  behavior
- **CLI**: Command injection, path traversal

## Out of Scope

- Denial of service via large inputs (the compiler processes untrusted input
  but runs locally)
- Issues in third-party dependencies (report upstream instead)
- WebGPU driver bugs triggered by valid WGSL shaders

## Supported Versions

| Version | Supported |
|---------|-----------|
| 2.x     | Yes       |
| 1.x     | No        |
| < 1.0   | No        |
