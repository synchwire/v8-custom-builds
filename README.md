<div align="center">
  <a href="https://wasmer.io" target="_blank" rel="noopener noreferrer">
    <img width="300" src="https://raw.githubusercontent.com/wasmerio/wasmer/master/assets/logo.png" alt="Wasmer logo">
  </a>
  
  <h1>wee8 Custom Builds</h1>
  
  <p>
    <a href="https://github.com/xdoardo/wee8-custom-builds/actions?query=workflow%3A%22Build%22">
      <img src="https://github.com/wasmerio/llvm-custom-builds/workflows/Build/badge.svg" alt="Build Status">
    </a>
    <a href="https://github.com/xdoardo/wee8-custom-builds/blob/master/LICENSE">
      <img src="https://img.shields.io/github/license/wasmerio/llvm-custom-builds.svg" alt="License">
    </a>
  </p>

  <h3>
    <a href="https://wasmer.io/">Website</a>
    <span> • </span>
    <a href="https://docs.wasmer.io">Docs</a>
    <span> • </span>
    <a href="https://slack.wasmer.io/">Slack Channel</a>
  </h3>

</div>

<hr/>

> Go along your path, this is a dangerous place.

## Upgrading V8

Notes from the V8 13.6.233.17 → 15.0.1 bump. When re-bumping V8 in the future,
run each patch in `patches/` through `git apply --check` against the new tag
and update them as needed.

- **0001 (sharedness of memory)**: still required. The `SharedFlag` enum was
  renamed in V8 14.x — `kNotShared` → `kNo`, `kShared` → `kYes`. Patch context
  updated accordingly.
- **0002 (tags / eh)**: still required, applied unchanged.
- **0003 (enable exnrefs by default)**: removed. The `experimental_wasm_exnref`
  flag no longer exists; exception handling has shipped, with `legacy_eh` in
  V8's shipped feature set and on by default.
- **0004 (gn-fix)**: removed. V8's `.gn` now uses `exec_script_allowlist`
  natively; the rename from `whitelist` happened upstream.
- **0005 (v128 in wasm-c-api)**: still required. `ValueType::heap_representation()`
  was renamed to `generic_kind()`; patch context updated.

Patches 0001 / 0002 / 0005 touch V8's internal C++ wasm-c-api implementation
and are likely to need ongoing maintenance as that surface evolves.
