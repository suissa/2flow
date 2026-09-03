# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**2flow** is a declarative DSL for orchestrating agent pipelines, distributed sagas, fork-join concurrency, and human-in-the-loop gates. The notation is parsed and validated entirely at Zig **comptime** (zero runtime parsing cost); the final binary gets a graph of native calls. A second track, **2FV (Two-Factor Validation)**, compiles the same validation tools to WebAssembly so the browser can run the backend's validation logic before making a network call.

The codebase (identifiers, comments, docs, commit messages) is in **Portuguese**. Match it when editing.

## Commands

No `build.zig` — everything goes through the `Makefile`, which calls `zig` directly. Target toolchain is **Zig 0.16.0**. The code uses recent std APIs (`std.ArrayList(T) = .empty` with allocator-passing `append`/`deinit`, `std.Io.Threaded`, `std.heap.DebugAllocator`, `@splat` array init) — the README/Makefile text mentioning 0.13 is stale.

```bash
make test          # zig test tests/main.zig  — core DSL parser + orchestrator tests
make test-wasm     # zig test wasm.zig        — 2FV WASM validator tests
make test-erp      # exercises the REAL engine (main.zig) with a complex end-to-end ERP flow
make test-all      # all of the above + both examples' test files
make wasm          # build 2flow.wasm (wasm32-freestanding, ReleaseSmall) from wasm.zig
make wasm-fast / make wasm-debug   # same, ReleaseFast / Debug
make run-datapipeline   # cd examples/data-pipeline && zig run main.zig
make run-empresa        # cd examples/empresa-agentica && zig run main.zig
make fmt           # zig fmt across all tracked Zig sources
```

`make` is not installed on the dev Windows box — run the recipe lines directly (see the `Makefile`). The code builds and all tests pass on both **Zig 0.16.0** (the version the docs target) and the 0.17.0-dev toolchain; it relies on `std.atomic.Mutex`, which exists in 0.16.0.

Run a single test by filter:

```bash
zig test tests/main.zig --test-filter "Operador de Canal de Erro"
```

The example test files are run from inside their own directory (they `@import("tools.zig")` and `@embedFile("config.2flow")` with relative paths):

```bash
cd examples/data-pipeline && zig test test_pipeline.zig
```

## Architecture

### The DSL and its four operators

| Operator | Meaning |
| --- | --- |
| `:--:` | Sequential pipeline — next node consumes previous node's success |
| `!->`  | Saga compensator — `NodeA !-> CompensatorA`; if `NodeA` fails, run `CompensatorA`, then abort the pipeline |
| `[a, b, ...]` | Fork-join — branches run concurrently, join is a barrier (all must succeed) |
| `[?Name]` | Human-in-the-loop gate — **documented in README but NOT implemented**; the tokenizer only accepts alphanumerics and `_`, so `?` currently fails to parse |

### Pipeline: tokenize → comptime AST → runtime orchestrator

1. `tokenize(comptime input)` → `[]const Token` (comptime).
2. `parseExpression` (recursive descent) → `NoFlowAST { tipo: .modulo | .sequencia | .paralelo, nome, filhos, compensador_erro }`.
3. `parse2Flow(comptime script)` returns the AST; callers do `comptime parse2Flow(...)`.
4. An **orchestrator** holds a `std.StringHashMap` catalog mapping agent name → handler `*const fn (ctx, *Event) bool`. `executar`/`executarFlow` walks the AST recursively:
   - `.modulo`: look up handler, call it; on `false`, fire `compensador_erro` if present, return `false`.
   - `.sequencia`: run children in order, stop on first failure.
   - `.paralelo`: spawn one `std.Thread` per branch, join all, fail if any branch failed. (Exception: `tests/main.zig`'s `TestOrchestrator` runs branches sequentially and adds a `forcar_falha_em` field to simulate a node failure.)

### This parser + orchestrator is copy-pasted, not shared

The same ~150-line tokenizer/parser/orchestrator block is **duplicated** in four files:

- `main.zig` (root demo — inline DSL string literal)
- `tests/main.zig` (core test suite, `TestOrchestrator`)
- `examples/data-pipeline/main.zig` (`PipelineOrchestrator`)
- `examples/empresa-agentica/main.zig`

A change to parser or orchestrator semantics must be replicated across all four. `wasm.zig` does **not** parse the DSL — it only does 2FV validation.

`tests/erp_complexo.zig` is the exception: it imports the real `main.zig` as a module (`zig test --dep flow -Mroot=tests/erp_complexo.zig -Mflow=main.zig`) instead of copying the parser, because Zig forbids `@import("../main.zig")` across the module boundary. Use that pattern to test the actual engine.

**Parser scaling limit:** `tokenize`/`parseExpression` run at comptime and blow the default 1000-backward-branch quota on any flow bigger than ~10 nodes. No call site in the repo raises it, so a real-world-sized flow fails to compile until the caller adds `@setEvalBranchQuota(...)` before `comptime parse2Flow(...)`.

### Event structs are the threaded mutable state

Each pipeline defines one struct ("Dado X" raw input → "Informação Y" enriched output) that every agent mutates in place: `EventoTransacional` (root), `TestEvent` (tests), `DataPipelineEvent` / `EmpresaEvent` (in each example's `tools.zig`). Business logic lives in `tools.zig` as stateless `*Tool` structs; the `agente*` functions in `main.zig` are thin adapters wiring a tool call to the event.

### `.2flow` config files

`examples/*/config.2flow` hold the flow expression as plain text, loaded with `@embedFile` and parsed at comptime. Editing a `.2flow` file changes the pipeline topology with no code change (as long as every referenced agent name is registered in that example's `main.zig`).

### 2FV / WebAssembly (`wasm.zig`)

Builds to `wasm32-freestanding` → `2flow.wasm` (committed to the repo root). Uses a static 128 KB `FixedBufferAllocator` (bump). Exports:
- `wasm_alloc(len)` / `wasm_reset_heap()` — JS writes payloads into linear memory, then resets.
- `validate_2fv_data_pipeline`, `validate_2fv_empresa`, `validate_2fv_json` — return `Status2FV` i32 codes (`SUCCESS = 1`, negatives for each failure class).

It `@import`s the examples' `tools.zig` to reuse their validation logic. The concept (`docs/2FV-TWO-FACTOR-VALIDATION-WASM.md`): Factor 1 = this module in the browser pre-flight; Factor 2 = authoritative server-side re-validation + ledger.

### Website

- `index.html` (repo root) — full landing page including an in-browser WASM sandbox runner.
- `site/` — a split refactor of the same page (`index.html` + `app.js` + `styles.css`), staged-scroll animations and an AST visualizer playground.

Both are static, no build step.
