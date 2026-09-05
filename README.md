# flake-lib

Shared library for the `jgus/*-flake` family of pinned-dependency sub-flakes. It generates the boilerplate those repos would otherwise hand-copy: the per-version-branch orchestrator, the `update-version` machinery, and PyPI package builders all come from a small declarative spec.

Consumers pin it as an input (`github:jgus/flake-lib/v1`) and pull improvements by
bumping that pin — the same `nix flake update` the orchestrator already runs per
branch. There is no copy-and-merge of scripts between repos.

## API (`flake-lib.lib`)

```nix
# High-level: a simple PyPI leaf collapses to one call.
flake-lib.lib.mkLeafFlake {
  inherit nixpkgs flake-utils;
  source  = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };  # pname = PyPI dist (underscore form)
  package = { attr = "iso639-lang"; description = "..."; };               # attr = nix attr (dash form)
  pin     = import ./pin.nix;
}
# => packages.<system> = { <attr>; update-version; update-branches; default; }

# Low-level: bespoke flakes supply their own package derivation.
flake-lib.lib.mkUpdateVersion  { pkgs; source; buildAttr; siblings ? []; siblingRefsInPin ? false; hashMode ? "prefetch"; extraHashes ? []; buildFailureHash ? null; artifactHook ? null; verification ? if buildFailureHash == null then "evaluate" else "build"; }
flake-lib.lib.mkUpdateBranches { pkgs; source; pinSchema; branchOwnedFiles ? [ "pin.nix" "flake.lock" ]; extraHashes ? []; versionOverrides ? {}; versionCanon ? []; minVersionComponents ? 3; }
flake-lib.lib.mkPypiPackage    { pkgs; source; package; pin; }
flake-lib.lib.mkRevalidateHash { pkgs; buildAttr; hashField ? "hash"; }
flake-lib.lib.mkJsDepsHook     { pkgs; manager; source ? "shipped"; field ? null; fetcherVersion ? null; }
flake-lib.lib.mkComposedHook   { pkgs; hooks; }
flake-lib.lib.versionMatchesComparison actual { operator; version; }

# Returns pkgs.${name}, emitting an eval warning when a version-numbered nixpkgs
# package (postgresql_18, php83, jdk21_headless, …) has a higher major available.
flake-lib.lib.warnIfNewerMajor { pkgs; name; lib ? pkgs.lib; }
```

`source.type` is `pypi`, `github`, `github-release-asset`, `huggingface`, or `gitlab`. `github`
hashes the source *tree* at a release tag (`{ version, sourceRev, sourceHash }`);
GitHub sources whose release tags have an additional prefix set `tagPrefix`, such as `source = { type = "github"; owner = "openai"; repo = "codex"; tagPrefix = "rust-v"; };`. Pins and version branches use the version without that prefix.
`github-release-asset` instead prefetches a single prebuilt release asset into a
`{ version, hash }` pin (`pinSchema = "github-asset"`), for upstreams shipped as a
ready-to-run binary/jar rather than built from source:

```nix
source = {
  type = "github-release-asset";
  owner = "Suwayomi"; repo = "Suwayomi-Server";
  asset = "Suwayomi-Server-v\${version}.jar";  # tokens: \${version} (tag minus leading v), \${tag}
  # tag = "\${version}";                        # optional; default "v\${version}"
};
```

`huggingface` tracks a model repository revision and writes a `{ version,
sourceRev }` pin. An optional `files` list adds a `hashes` attribute containing
the Nix content hash of each selected repository file:

```nix
source = {
  type = "huggingface";
  repo = "BAAI/bge-reranker-v2-m3";
  files = [ "config.json" "model.safetensors" ];
};
```

The update machinery and the orchestrator's per-flake bits
(`list_upstream_versions`, `prepare_new_branch_pin`, and sibling cascades) are all driven from that spec. `version-only` preserves the current complete pin while creating a branch so a bespoke updater can evaluate and atomically replace it with the target version's complete pin.

PyPI producers resolve sibling requirements from their release metadata. Exact pins select exact branches, unbounded minimums select `main`, and bounded ranges select a compatible aggregate. Prerelease exact branches are always maintained. A prerelease advances each aggregate independently only when that aggregate is absent or already tracks a prerelease; stable aggregates remain stable until a newer stable release replaces them.

GitHub producers read sibling requirements from `reqFile = "requirements.txt"` by default. Set `reqFormat = "pyproject"`, `reqFile = "pyproject.toml"`, and `reqGroups = [ "extra-name" ]` to combine `[project].dependencies` with selected optional-dependency groups. Environment markers are evaluated before the compatible branch is selected.

Set `siblingRefsInPin = true` to write the resolved refs under `pin.nix.dependencies` instead of rewriting `flake.nix`. The updater applies those refs while regenerating `flake.lock`, so each historical branch owns its complete source and dependency selection through `pin.nix` and `flake.lock` while `flake.nix` retains generic input URLs.

Update verification evaluates the target package's derivation on every run. Set `verification = "build"` only when the producer must realize the package before publishing its pin. A non-null `buildFailureHash` selects build verification because the successful rebuild is part of deriving that pin.

`buildFailureHash` names one additional pin field whose value is populated from
the package build's fixed-output hash mismatch. This supports dependency fetchers
such as `fetchPnpmDeps` while the source tree continues to use normal prefetching.
For PyPI sources, pass the same field through `mkUpdateBranches.extraHashes` so
new version branches include it in their placeholder pins.
Use `pinSchema = "github-pnpm"` for the corresponding `{ version, sourceRev,
sourceHash, pnpmDepsHash }` branch placeholders.

`templates/` holds `gitattributes` and `workflow.yml`, which a consuming repo installs as `.gitattributes` and `.github/workflows/update.yml`.

## Versioning

Hand-versioned via git tags (`vX.Y.Z`) with a moving `v1` aggregate branch. Breaking
changes bump to `v2`; consumers migrate deliberately, so one push can't break every
repo at once.
