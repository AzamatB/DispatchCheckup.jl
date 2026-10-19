# DispatchCheckup 0.2 redesign specification

Status: **decisions final, implementation not started.** This branch (`redesign-0.2`) carries
the specification; `main` stays at v0.1.2 until the redesign merges as 0.2.0.

## Summary

0.2 keeps the 0.1 user contract (two lines at the top of `test/runtests.jl`, and commenting
them out makes the run as if DispatchCheckup did not exist) and rebuilds everything behind it:

- **In-process activation.** No child relaunch. `dispatch_doctor` prepends a generated
  environment, builds a precompiled instrumented image of the target, and validates, reports
  and runs guard files from an `atexit` hook.
- **Original identity.** The overlay is a `Project.toml` copy plus entry shims; `pkgdir` and
  `pathof` report the real checkout. No source tree copy or symlinks.
- **Owned check wrapper.** DispatchCheckup generates its own per-definition wrapper from a
  template derived from DispatchDoctor 0.4.29, using DispatchDoctor as a runtime library.
- **Record mode by default.** The real function body runs, every instability is recorded, and
  the run fails at the end with the full list. `mode=:error` restores throw-at-the-call.
- **Six keywords.**

  ```julia
  dispatch_doctor(:MyPackage;
      unstable = (),        # not wrapped, not checked (DispatchDoctor's @unstable semantics)
      original = (),        # guard files run against the original code after the suite
      union_limit = 1,
      require_all = false,  # fail on unacknowledged blind spots
      mode = :record,
      report = nothing)
  ```

- **Julia 1.13 only**; dependencies reduced to DispatchDoctor, MacroTools and TOML.

## Sections

| Section | File | Contents |
|---|---|---|
| S1 | [01-overview.md](01-overview.md) | Scope, hard requirement and Design A, non-goals, glossary, full decision log, changes from 0.1, open points |
| S2 | [02-architecture.md](02-architecture.md) | Process model, environment, overlay identity, images and caches, config transport, image hooks, descendants, integrity checks, source layout |
| S3 | [03-checking.md](03-checking.md) | Owned wrapper template, record mode, AD transparency, scope and by-design skips, records and method-table audit, macro policy, `require_all` |
| S4 | [04-api.md](04-api.md) | Signature and keyword semantics, `unstable=` grammar, activation state machine, environment variables and CI gate, guards, report schema, as-if-absent contract, migration from 0.1 |
| S5 | [05-engineering.md](05-engineering.md) | Dependencies and compat, platforms, CI, test strategy, release, licensing, phase plan, risks |
| S6a | [06-jll.md](06-jll.md) | Policy for JLLWrappers targets |

The per-repository consumer migration plan (S6b) covers private repositories and is maintained
outside this repository. Evidence citations of the form `$AUDIT/<directory>` refer to the
maintainer's local review archive, which is not part of this repository.

## Open for the owner

1. **Consumer rollout** (S1 open point 12, S5 D27): the rollout path for the consumer
   integration PRs that are still open, and whether a consumer that cannot migrate on merge day
   may temporarily pin `rev = "v0.1.2"`.

Effort is estimated at about 1–2 days of agent wall-clock time plus review (S5 Effort).

One technical point is settled by prototype rather than by the owner: whether the private
depot must mirror `dev/` and `packages/` for depot relocation (S2 D17+D47, the first Phase 1
task in S5).
