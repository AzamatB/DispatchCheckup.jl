# S6a JLL targets (O10)

DispatchCheckup (DC) 0.2 policy for JLLWrappers packages; acceptance case GodelaAMGX_jll. Replaces D23's "delete the JLL path" and amends D08(4), D13, D23(3) and D44 where marked.

## Evidence

- **GodelaAMGX_jll** (c958fc6). Its root is a `baremodule` (src/GodelaAMGX_jll.jl:2). Line 6 includes `.pkg/platform_augmentation.jl`, which sits outside src/, **before** the header at :9. Line :10 is `@generate_main_file`.
  - Handwritten definitions: `cuda_comparison_strategy` (.pkg/platform_augmentation.jl:17), its closure `is_compatible` (:36) and `augment_platform!` (:52).
  - The wrapper files `src/wrappers/*-cuda+{12.9,13.3}.jl` are BinaryBuilder output: macro calls plus `__init__` (:7).
  - Generated methods (`is_available`, `dev_jll`, `find_artifact_dir`, `eager_mode`, `get_libamgxsh_path`) report a JLLWrappers file:line.
- **JLLWrappers 1.8.0.**
  - The header evaluates `@compiler_options compile=min optimize=0 infer=false` when the `disable_optimization` preference holds. It defaults to true (toplevel_generators.jl:52-58, JLLWrappers.jl:8).
  - `@generate_main_file` emits `Base.include(<Pkg>_jll, best_wrapper)` with a path computed at load time (toplevel_generators.jl:202). No other JLLWrappers macro includes.
  - Paths come from `__source__.file`: `override/`, `Artifacts.toml` and `wrappers/` (toplevel_generators.jl:110,138,167; wrapper_generators.jl:6-10).
- **Production** (S6a probe, image load).
  - `jl_get_module_infer(GodelaAMGX_jll) == 0`, and `promote_op` is `Any` for both handwritten and generated methods.
  - The flag also covers methods defined before it. A submodule created before the flag inherits 0. See `$AUDIT/D08-default-check-scope-v3n7/e1_infer.jl` and `e3.jl`.
- **v0.1.2**, checked run on a copy: passes with 3 instrumented and 5 unsupported. It gets there only by re-enabling inference (instrumentation.jl:572-576), which changes semantics: in `$AUDIT/D23-special-cases-k9w4/jll`, production returns `unstable(true)=1` but the checked run throws.
- **Without the JLL path** the generated include trips the bypass check and the run exits 1 (`$AUDIT/D23-special-cases-k9w4/jll/nojll.log`).

## Decision

JLL targets load and pass. DC maps the generated platform include and never emits compiler options. Every definition in an inference-disabled module is skipped by design. For GodelaAMGX_jll the result is "nothing checkable", status passed.

## Requirements

1. **Vetted JLLWrappers entries** in the D06/D07 table. They match by binding, never by a `_jll` name: the defining module's PkgId UUID must be `692b3bcd-3c85-4b1f-b108-f13ce0eb3210` (JLLWrappers 1.x).
   - `@generate_main_file`: expand it once (`macroexpand(...; recursive=false)`, which is pure), apply only the native-include rewrite and wrap nothing. The expansion must contain exactly one include. Otherwise pass it through with a `blind_spot(opaque_macro)` record (S3.8), and the include observer then fails closed on the unmapped include.
   - The ten other JLLWrappers macros pass through unchanged.
   - Each site pushes one evaluation-time `not_applicable(by_design.jll_generated)` record (S3.4). It is not counted by require_all, which counts only blind spots not listed in `unstable=`.
   - A same-spelled macro from any other module stays opaque (D07).
2. **Mapper.** It accepts dynamic paths and files outside `src/`, scoped by owned module (D46(4)).
3. **Inference rule** (D08, applies to every module):
   - At expansion: if `jl_get_module_infer(__module__) == 0`, the definition is emitted unwrapped with a by-design record.
   - At call time: the instability branch of the template (the `@noinline` host helper on the cold path) first tests `jl_get_module_infer(<defining module>) == 0`. If it is 0, the helper neither records nor throws, in either mode. This makes late-flag wrappers inert, such as GodelaAMGX_jll's `.pkg` functions. The stable path is unchanged and stays GPU-safe.
   - At finalization: every record in a module whose flag is 0 becomes `not_applicable(by_design.infer_disabled)` (S3.4), overriding the `checked`, `limitation` and `blind_spot` classes.
   - **Amends D08(4):** a late flag is not a configuration error. **Overrides D23(3):** a target with every owned module disabled gets a summary note, not a failure.
   - DC never emits `@compiler_options`. With `disable_optimization=false`, the module is checked normally.
4. **Hook in a baremodule** (amends D13). The walker inserts the private submodule into `baremodule` roots, using GlobalRefs only.
   - The hook inherits the root's flag. When that flag is 0, the canary and self-test are skipped and the image is recorded as inference-disabled.
   - The hook defines no structs, exports or foreign methods. GodelaAMGX_jll's CheckConcreteStructs test walks the submodules in `names(M; all=true)`.
5. **D44 audit.** Methods in infer-disabled modules are by design. Owned methods located in JLLWrappers' files are attributed to the vetted site.
6. **Preferences and identity.**
   - The generated environment adds only DC's `dispatch_checkup` table to the copied user view. It writes no DispatchDoctor key and never `__clear__` (S2 D24, D45). Base merges preferences per key (loading.jl:3934-3988).
   - The target's `libamgxsh_path` and CUDA_Runtime_jll's "version"/"local" preferences resolve exactly as in production.
   - D13 identity keeps `override/`, `Artifacts.toml` and `wrappers/` in the checkout.

## GodelaAMGX_jll report (this host selects cuda+13.3)

- `status = "passed"`.
- Module `GodelaAMGX_jll`: `inference = "disabled"` (flag site :9), 0 checked.
- By design:
  - `cuda_comparison_strategy` (wrapped, then inert);
  - `is_compatible` and `augment_platform!`;
  - the JLLWrappers sites (entry :9 and :10, wrapper :5 and :6);
  - `__init__`.
- 0 instabilities, 0 blind spots.
- Mapped files: the entry, `.pkg/platform_augmentation.jl` and the selected wrapper.
- Console: `GodelaAMGX_jll: nothing checkable — inference disabled in every owned module`.
- Same result with `require_all=true` and with `mode=:error`.

## Tests

- **Rewrite the JLLLoader fixture** (D26). It becomes a baremodule with a `.pkg` include before the header defining an unstable function the test calls, plus `any.jl`.
  - Assert that it loads, `unstable(true) == 1` in both modes, the checked process sees infer flag 0, the report matches the shape above and require_all passes.
  - Delete the v0.1.2 assertion that the call throws.
- **Same fixture with `disable_optimization=false`:** the instability is recorded.
- **Impostor `@generate_main_file`:** fails with the bypass error.
- **Drifted expansion with no include:** fails closed.
- **Twin (D51):** `pkgdir`, `is_available()`, the artifact dir, `override/` and preferences all equal production.
- **D36 GPU tier:** GodelaAMGX_jll's checked suite on the L40S host.

## Resolved point

- **Reserved prefix versus consumer variables (S4 D31). Resolved (default).** D31 reserves the `DISPATCH_CHECKUP_*` prefix, but GodelaAMGX_jll and the other internal consumers read a report-path variable under that prefix (`DISPATCH_CHECKUP_REPORT`) themselves in test code. DC ignores unknown `DISPATCH_CHECKUP_*` variables and lists them in the banner; it never rejects them (S4 D31). Consumers may keep reading their own variables in test code, so this point needs no consumer change. Any per-consumer cleanup is tracked in the private consumer migration plan (S6b, maintained outside this repository).
