## Related Plans (Reference as Needed)

| Plan                                        | Purpose                                  | Status      |
| ------------------------------------------- | ---------------------------------------- | ----------- |
| `docs/cpu-wasm-data-initialization-plan.md` | **ACTIVE** - Buffer init + shapes        | In Progress |
| `docs/embedded-executor-plan.md`            | Embedded executor + plugins              | Complete    |
| `docs/llm-runtime-testing-plan.md`          | LLM-friendly validation via wasm3        | Complete    |
| `docs/multiplatform-command-buffer-plan.md` | Platform abstraction                     | Reference   |
| `docs/data-generation-plan.md`              | Compute shader data gen (superseded)     | Archived    |
| `docs/command-buffer-refactor-plan.md`      | JS bundle optimization                   | Reference   |
| `docs/remove-wasm-in-wasm-plan.md`          | **SUPERSEDED** - Do not use              | Archived    |

### Buffer Initialization (docs/cpu-wasm-data-initialization-plan.md)

Two approaches for buffer initialization:

**1. Compile-time shapes** (static meshes):
```
#data cubeVertexArray {
  cube={ format=[position4 color4 uv2] }
}
```

**2. Compute shader #init** (procedural data):
```
#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[42]
}
```

Key features:

- **Built-in shapes**: `cube=`, `plane=`, `sphere=` with format specifiers
- **Auto-sizing**: `size=shader.varName` uses reflection
- **One-time init**: `#frame { init=[...] }` runs before first frame
- **GPU-native**: Compute shaders for procedural data

---

