# PNGine TextMate Grammar Plan

## Overview

A TextMate grammar for the PNGine DSL that powers:
1. **Shiki** - Static syntax highlighting on landing page (build-time)
2. **VS Code extension** - Editor syntax highlighting
3. **CodeMirror 6** - Web editor (via shiki or conversion)

The grammar must handle the unique challenges of PNGine's DSL: macro-based syntax, embedded WGSL, expression evaluation, and WebGPU-specific constants.

---

## DSL Syntax Summary

### Macros (24 types)

```
#wgsl              #shaderModule       #buffer
#texture           #sampler            #textureView
#bindGroup         #bindGroupLayout    #pipelineLayout
#renderPipeline    #computePipeline    #renderPass
#computePass       #renderBundle       #frame
#data              #define             #queue
#init              #querySet           #imageBitmap
#wasmCall          #import             #animation
```

### Structure Patterns

```pngine
// Macro with name and body
#macroType name {
  property=value
  property=[array values]
  property={ nested=object }
}

// Define (special: no braces)
#define NAME=value
#define NAME="expression"

// Import (special: string path)
#import "path/to/file.pngine"
```

### Value Types

| Type | Examples |
|------|----------|
| **String** | `"hello"`, `"multi\nline"`, `code="@vertex fn main()..."` |
| **Number** | `123`, `0.5`, `-1.5`, `0xFF`, `0x1A` |
| **Boolean** | `true`, `false` |
| **Identifier** | `auto`, `clear`, `store`, `vertexMain` |
| **Expression** | `4 * 4`, `ceil(NUM_PARTICLES / 64)`, `(2 * PI) / 5` |
| **Array** | `[VERTEX STORAGE]`, `[0.0 0.5 1.0]`, `[pass1 pass2]` |
| **Object** | `{ binding=0 resource={ buffer=buf } }` |
| **Reference** | `contextCurrentTexture`, `canvas.width`, `pngineInputs` |

### WebGPU Constants

**Buffer Usage Flags:**
```
VERTEX  STORAGE  UNIFORM  INDEX  INDIRECT
COPY_SRC  COPY_DST  MAP_READ  MAP_WRITE  QUERY_RESOLVE
```

**Texture Usage Flags:**
```
TEXTURE_BINDING  STORAGE_BINDING  RENDER_ATTACHMENT
COPY_SRC  COPY_DST
```

**Primitive Topology:**
```
point-list  line-list  line-strip  triangle-list  triangle-strip
```

**Load/Store Operations:**
```
load  clear  store  discard
```

**Compare Functions:**
```
never  less  equal  less-equal  greater  not-equal  greater-equal  always
```

**Cull Modes:**
```
none  front  back
```

**Vertex Formats:**
```
uint8x2  uint8x4  sint8x2  sint8x4  unorm8x2  unorm8x4  snorm8x2  snorm8x4
uint16x2  uint16x4  sint16x2  sint16x4  unorm16x2  unorm16x4  snorm16x2  snorm16x4
float16x2  float16x4  float32  float32x2  float32x3  float32x4
uint32  uint32x2  uint32x3  uint32x4  sint32  sint32x2  sint32x3  sint32x4
unorm10-10-10-2
```

**Texture Formats:**
```
rgba8unorm  rgba8snorm  rgba8uint  rgba8sint
bgra8unorm  rg32float  rgba16float  rgba32float
depth24plus  depth32float  depth24plus-stencil8
r8unorm  r16float  r32float  rg8unorm  rg16float
```

### Built-in Identifiers

```
// Canvas/context references
contextCurrentTexture    preferredCanvasFormat
canvas.width             canvas.height

// Runtime data sources
pngineInputs             sceneTimeInputs

// Shape generators (in #data)
cube  plane  sphere

// Special values
auto
```

### Math Constants & Functions

```
// Constants
PI  TAU  E

// Functions (in expressions)
ceil  floor  round  abs  min  max  sqrt  sin  cos  tan
```

---

## TextMate Grammar Structure

### Scope Naming Convention

Following [TextMate conventions](https://macromates.com/manual/en/language_grammars#naming_conventions):

| Element | Scope |
|---------|-------|
| `#macroType` | `keyword.control.macro.pngine` |
| Macro name | `entity.name.function.macro.pngine` |
| Property key | `variable.other.property.pngine` |
| `=` | `keyword.operator.assignment.pngine` |
| String | `string.quoted.double.pngine` |
| Number | `constant.numeric.pngine` |
| Boolean | `constant.language.boolean.pngine` |
| Usage flags | `constant.language.usage.pngine` |
| WebGPU enums | `constant.language.enum.pngine` |
| Built-in refs | `support.variable.builtin.pngine` |
| Math constants | `support.constant.math.pngine` |
| Math functions | `support.function.math.pngine` |
| `{ }` | `punctuation.section.braces.pngine` |
| `[ ]` | `punctuation.section.brackets.pngine` |
| `( )` | `punctuation.section.parens.pngine` |
| Comment | `comment.line.double-slash.pngine` |
| Embedded WGSL | `meta.embedded.block.wgsl` |

### Grammar File Structure

```json
{
  "$schema": "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
  "name": "PNGine",
  "scopeName": "source.pngine",
  "fileTypes": ["pngine"],
  "patterns": [
    { "include": "#comments" },
    { "include": "#define" },
    { "include": "#import" },
    { "include": "#macro" }
  ],
  "repository": {
    // Pattern definitions...
  }
}
```

---

## Pattern Definitions

### 1. Comments

```json
"comments": {
  "patterns": [
    {
      "name": "comment.line.double-slash.pngine",
      "match": "//.*$"
    }
  ]
}
```

### 2. Define Macro (Special Case)

```json
"define": {
  "match": "(#define)\\s+([A-Z_][A-Z0-9_]*)\\s*(=)\\s*(.+?)\\s*$",
  "captures": {
    "1": { "name": "keyword.control.macro.define.pngine" },
    "2": { "name": "entity.name.constant.pngine" },
    "3": { "name": "keyword.operator.assignment.pngine" },
    "4": { "patterns": [{ "include": "#expression" }] }
  }
}
```

### 3. Import Macro (Special Case)

```json
"import": {
  "match": "(#import)\\s+(\"[^\"]+\")",
  "captures": {
    "1": { "name": "keyword.control.macro.import.pngine" },
    "2": { "name": "string.quoted.double.import.pngine" }
  }
}
```

### 4. Standard Macros

```json
"macro": {
  "begin": "(#(?:wgsl|shaderModule|buffer|texture|sampler|textureView|bindGroup|bindGroupLayout|pipelineLayout|renderPipeline|computePipeline|renderPass|computePass|renderBundle|frame|data|queue|init|querySet|imageBitmap|wasmCall|animation))\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s*({)",
  "beginCaptures": {
    "1": { "name": "keyword.control.macro.pngine" },
    "2": { "name": "entity.name.function.macro.pngine" },
    "3": { "name": "punctuation.section.braces.begin.pngine" }
  },
  "end": "}",
  "endCaptures": {
    "0": { "name": "punctuation.section.braces.end.pngine" }
  },
  "patterns": [
    { "include": "#comments" },
    { "include": "#property" }
  ]
}
```

### 5. Properties

```json
"property": {
  "begin": "([a-zA-Z_][a-zA-Z0-9_]*)\\s*(=)",
  "beginCaptures": {
    "1": { "name": "variable.other.property.pngine" },
    "2": { "name": "keyword.operator.assignment.pngine" }
  },
  "end": "(?=[}\\]\\n]|[a-zA-Z_][a-zA-Z0-9_]*\\s*=)",
  "patterns": [
    { "include": "#value" }
  ]
}
```

### 6. Values

```json
"value": {
  "patterns": [
    { "include": "#comments" },
    { "include": "#wgsl-string" },
    { "include": "#string" },
    { "include": "#number" },
    { "include": "#boolean" },
    { "include": "#array" },
    { "include": "#object" },
    { "include": "#expression" },
    { "include": "#identifier" }
  ]
}
```

### 7. Strings (Regular)

```json
"string": {
  "name": "string.quoted.double.pngine",
  "begin": "\"",
  "end": "\"",
  "patterns": [
    {
      "name": "constant.character.escape.pngine",
      "match": "\\\\."
    }
  ]
}
```

### 8. WGSL Embedded Strings (Critical)

This is the most complex pattern - it detects `code="..."` or `value="..."` in shader-related macros and applies WGSL highlighting inside.

```json
"wgsl-string": {
  "begin": "(code|value)\\s*(=)\\s*(\")",
  "beginCaptures": {
    "1": { "name": "variable.other.property.pngine" },
    "2": { "name": "keyword.operator.assignment.pngine" },
    "3": { "name": "string.quoted.double.begin.pngine" }
  },
  "end": "\"",
  "endCaptures": {
    "0": { "name": "string.quoted.double.end.pngine" }
  },
  "contentName": "meta.embedded.block.wgsl",
  "patterns": [
    { "include": "source.wgsl" }
  ]
}
```

**Note:** This requires the WGSL grammar to be available. Shiki and VS Code both have WGSL grammars built-in.

### 9. Numbers

```json
"number": {
  "patterns": [
    {
      "name": "constant.numeric.hex.pngine",
      "match": "0[xX][0-9a-fA-F]+"
    },
    {
      "name": "constant.numeric.float.pngine",
      "match": "-?\\d+\\.\\d*|\\d*\\.\\d+"
    },
    {
      "name": "constant.numeric.integer.pngine",
      "match": "-?\\d+"
    }
  ]
}
```

### 10. Booleans

```json
"boolean": {
  "name": "constant.language.boolean.pngine",
  "match": "\\b(true|false)\\b"
}
```

### 11. Arrays

```json
"array": {
  "begin": "\\[",
  "beginCaptures": {
    "0": { "name": "punctuation.section.brackets.begin.pngine" }
  },
  "end": "\\]",
  "endCaptures": {
    "0": { "name": "punctuation.section.brackets.end.pngine" }
  },
  "patterns": [
    { "include": "#comments" },
    { "include": "#value" }
  ]
}
```

### 12. Nested Objects

```json
"object": {
  "begin": "{",
  "beginCaptures": {
    "0": { "name": "punctuation.section.braces.begin.pngine" }
  },
  "end": "}",
  "endCaptures": {
    "0": { "name": "punctuation.section.braces.end.pngine" }
  },
  "patterns": [
    { "include": "#comments" },
    { "include": "#property" }
  ]
}
```

### 13. WebGPU Constants

```json
"usage-flags": {
  "name": "constant.language.usage.pngine",
  "match": "\\b(VERTEX|STORAGE|UNIFORM|INDEX|INDIRECT|COPY_SRC|COPY_DST|MAP_READ|MAP_WRITE|QUERY_RESOLVE|TEXTURE_BINDING|STORAGE_BINDING|RENDER_ATTACHMENT)\\b"
},

"webgpu-enums": {
  "name": "constant.language.enum.pngine",
  "match": "\\b(point-list|line-list|line-strip|triangle-list|triangle-strip|load|clear|store|discard|never|less|equal|less-equal|greater|not-equal|greater-equal|always|none|front|back|depth24plus|depth32float|depth24plus-stencil8|rgba8unorm|rgba8snorm|bgra8unorm|r8unorm|rg8unorm|rgba16float|rgba32float|rg32float|r16float|r32float|float32|float32x2|float32x3|float32x4|uint32|sint32|vertex|instance)\\b"
}
```

### 14. Built-in Identifiers

```json
"builtin-variables": {
  "name": "support.variable.builtin.pngine",
  "match": "\\b(contextCurrentTexture|preferredCanvasFormat|pngineInputs|sceneTimeInputs|auto)\\b"
},

"canvas-properties": {
  "match": "(canvas)\\s*(\\.)(width|height)",
  "captures": {
    "1": { "name": "support.variable.builtin.pngine" },
    "2": { "name": "punctuation.accessor.pngine" },
    "3": { "name": "support.variable.property.pngine" }
  }
}
```

### 15. Expressions

```json
"expression": {
  "patterns": [
    { "include": "#math-constants" },
    { "include": "#math-functions" },
    { "include": "#operators" },
    { "include": "#number" },
    { "include": "#identifier-ref" }
  ]
},

"math-constants": {
  "name": "support.constant.math.pngine",
  "match": "\\b(PI|TAU|E)\\b"
},

"math-functions": {
  "name": "support.function.math.pngine",
  "match": "\\b(ceil|floor|round|abs|min|max|sqrt|sin|cos|tan)\\b"
},

"operators": {
  "name": "keyword.operator.arithmetic.pngine",
  "match": "[+\\-*/]"
}
```

### 16. Identifiers (Catch-All)

```json
"identifier": {
  "name": "variable.other.pngine",
  "match": "[a-zA-Z_][a-zA-Z0-9_]*"
}
```

---

## Implementation Plan

### Phase 1: Core Grammar (Week 1)

1. **Create base grammar file**: `syntaxes/pngine.tmLanguage.json`
2. **Implement patterns in order**:
   - Comments
   - Define macro
   - Import macro
   - Standard macros (begin/end regions)
   - Properties
   - Basic values (strings, numbers, booleans)
   - Arrays and nested objects
3. **Test with simple examples**: `simple_triangle.pngine`

### Phase 2: WebGPU Specifics (Week 1-2)

1. **Add WebGPU constants**:
   - Usage flags (VERTEX, STORAGE, etc.)
   - Enum values (topology, loadOp, etc.)
   - Texture/vertex formats
2. **Add built-in identifiers**:
   - contextCurrentTexture, preferredCanvasFormat
   - canvas.width, canvas.height
   - pngineInputs, sceneTimeInputs
3. **Test with complex examples**: `rotating_cube.pngine`, `boids.pngine`

### Phase 3: Embedded WGSL (Week 2)

1. **Implement WGSL string detection**:
   - Pattern for `code="..."` and `value="..."`
   - Include WGSL grammar for content
2. **Handle multiline strings**:
   - Strings can span many lines
   - Must correctly delimit start/end
3. **Test**: Verify WGSL keywords, types, built-ins highlighted inside strings

### Phase 4: Expressions (Week 2-3)

1. **Math expressions**:
   - Constants: PI, TAU, E
   - Functions: ceil(), floor(), sqrt(), etc.
   - Operators: +, -, *, /
   - Parentheses grouping
2. **Identifier references in expressions**:
   - Define references: `NUM_PARTICLES * 4`
   - Property references: `canvas.width`
3. **String expressions**: `"4 * 4"` should highlight expression inside

### Phase 5: Polish & Edge Cases (Week 3)

1. **Edge cases**:
   - Nested braces in WGSL strings
   - Comments inside arrays/objects
   - Escaped quotes in strings
2. **Theme testing**:
   - Test with popular themes (Dracula, One Dark, Monokai)
   - Ensure colors are distinct and meaningful
3. **Documentation**:
   - Create theme color guide
   - Document scope names

---

## File Deliverables

```
syntax/
├── pngine.tmLanguage.json    # Main TextMate grammar
├── pngine.tmLanguage.yaml    # Source (easier to edit, convert to JSON)
├── test/
│   ├── simple.pngine         # Basic syntax test
│   ├── complex.pngine        # All features test
│   └── edge-cases.pngine     # Edge cases test
└── themes/
    └── pngine-dark.json      # Optional: custom theme
```

---

## Integration Points

### Shiki (Landing Page)

```javascript
import { createHighlighter } from 'shiki'

const highlighter = await createHighlighter({
  themes: ['vitesse-dark'],
  langs: [
    // Load custom PNGine grammar
    {
      id: 'pngine',
      scopeName: 'source.pngine',
      path: './syntaxes/pngine.tmLanguage.json',
      embeddedLangs: ['wgsl']  // Required for embedded WGSL
    }
  ]
})

const html = highlighter.codeToHtml(code, { lang: 'pngine', theme: 'vitesse-dark' })
```

### VS Code Extension

```json
// package.json
{
  "contributes": {
    "languages": [{
      "id": "pngine",
      "extensions": [".pngine"],
      "configuration": "./language-configuration.json"
    }],
    "grammars": [{
      "language": "pngine",
      "scopeName": "source.pngine",
      "path": "./syntaxes/pngine.tmLanguage.json",
      "embeddedLanguages": {
        "meta.embedded.block.wgsl": "wgsl"
      }
    }]
  }
}
```

### CodeMirror 6 (Web Editor)

Two approaches:

**A. Use shikiji (Shiki for CodeMirror)**
```javascript
import { shikiToCodeMirror } from '@shikijs/codemirror'

const extensions = await shikiToCodeMirror(highlighter, { lang: 'pngine' })
```

**B. Native Lezer grammar** (more work, better integration)
```javascript
// Convert TextMate → Lezer grammar
// Requires manual translation of patterns
```

Recommendation: Start with shikiji, migrate to Lezer only if performance is an issue.

---

## Testing Strategy

### Unit Tests

For each pattern, test:
1. **Positive match**: Pattern matches expected input
2. **Negative match**: Pattern doesn't match invalid input
3. **Scope assignment**: Correct scope names applied

### Integration Tests

1. **File-level**: Full .pngine files highlight correctly
2. **Theme-level**: Colors are distinct across themes
3. **Editor-level**: Bracket matching, folding work

### Test Files

```pngine
// test/comprehensive.pngine
// Tests all syntax features

#define PI_APPROX=3.14159
#define BUFFER_SIZE="64 * 1024"

#import "shared/utils.pngine"

#buffer myBuffer {
  size=BUFFER_SIZE
  usage=[VERTEX STORAGE COPY_DST]
}

#shaderModule myShader {
  code="
    @vertex
    fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
      return vec4f(0.0, 0.0, 0.0, 1.0);
    }
  "
}

#renderPipeline myPipeline {
  layout=auto
  vertex={
    module=myShader
    entrypoint=main
    buffers=[{
      arrayStride="4 * 4"
      stepMode=vertex
      attributes=[
        { shaderLocation=0 offset=0 format=float32x4 }
      ]
    }]
  }
  fragment={
    module=myShader
    entrypoint=frag
    targets=[{ format=preferredCanvasFormat }]
  }
  primitive={ topology=triangle-list cullMode=back }
  depthStencil={
    format=depth24plus
    depthWriteEnabled=true
    depthCompare=less
  }
}

#texture depthTex {
  size=[canvas.width canvas.height]
  format=depth24plus
  usage=[RENDER_ATTACHMENT]
}

#renderPass myPass {
  colorAttachments=[{
    view=contextCurrentTexture
    clearValue=[0.0 0.0 0.0 1.0]
    loadOp=clear
    storeOp=store
  }]
  depthStencilAttachment={
    view=depthTex
    depthClearValue=1.0
    depthLoadOp=clear
    depthStoreOp=store
  }
  pipeline=myPipeline
  vertexBuffers=[myBuffer]
  draw=3
}

#frame main {
  perform=[myPass]
}
```

---

## Complexity Estimate

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| Phase 1: Core | 2-3 days | None |
| Phase 2: WebGPU | 1-2 days | Phase 1 |
| Phase 3: WGSL | 2-3 days | Phase 1, WGSL grammar |
| Phase 4: Expressions | 1-2 days | Phase 1 |
| Phase 5: Polish | 1-2 days | All phases |
| **Total** | **7-12 days** | |

---

## Open Questions

1. **WGSL grammar source**: Use VS Code's built-in, or bundle separately?
   - Recommendation: Require WGSL grammar as dependency (widely available)

2. **Expression string highlighting**: Should `"4 * 4"` highlight as expression or string?
   - Recommendation: String with expression highlighting inside (complex but useful)

3. **Folding regions**: Add folding markers for macros?
   - Recommendation: Yes, `#macroType {` to `}` should fold

4. **Bracket matching**: Handle nested WGSL brackets?
   - Recommendation: Embedded language handles its own brackets

5. **Semantic tokens**: Add LSP semantic tokens for enhanced highlighting?
   - Recommendation: Phase 2 (after basic TextMate grammar works)

---

## Success Criteria

1. **All 24 macro types** highlighted with correct keyword scope
2. **All WebGPU constants** (50+) highlighted as language constants
3. **Embedded WGSL** gets full WGSL highlighting
4. **Expressions** show math functions/constants distinctly
5. **Works in**: Shiki, VS Code, CodeMirror (via shikiji)
6. **Theme compatibility**: Tested with 3+ popular themes
7. **No false positives**: Regular identifiers don't get special highlighting
