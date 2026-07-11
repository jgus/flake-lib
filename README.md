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
flake-lib.lib.mkUpdateVersion  { pkgs; source; buildAttr; siblings ? []; hashMode ? "prefetch"; extraHashes ? []; artifactHook ? null; }
flake-lib.lib.mkUpdateBranches { pkgs; source; pinSchema; branchOwnedFiles ? [ "pin.nix" "flake.lock" ]; versionOverrides ? {}; versionCanon ? []; excludePrereleases ? false; minVersionComponents ? 3; }
flake-lib.lib.mkPypiPackage    { pkgs; source; package; pin; }
flake-lib.lib.mkRevalidateHash { pkgs; buildAttr; hashField ? "hash"; }
flake-lib.lib.mkJsDepsHook     { pkgs; manager; source ? "shipped"; field ? null; fetcherVersion ? null; }
flake-lib.lib.mkComposedHook   { pkgs; hooks; }

# Returns pkgs.${name}, emitting an eval warning when a version-numbered nixpkgs
# package (postgresql_18, php83, jdk21_headless, …) has a higher major available.
flake-lib.lib.warnIfNewerMajor { pkgs; name; lib ? pkgs.lib; }
```

`source.type` is `pypi`, `github`, `github-release-asset`, or `gitlab`. `github`
hashes the source *tree* at a release tag (`{ version, sourceRev, sourceHash }`);
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

The update machinery and the orchestrator's per-flake bits
(`list_upstream_versions`, `write_placeholder_pin`, the sibling-cascade URL
rewrite) are all driven from that spec.

`templates/` holds `gitattributes` and `workflow.yml`, which a consuming repo installs as `.gitattributes` and `.github/workflows/update.yml`.

## Versioning

Hand-versioned via git tags (`vX.Y.Z`) with a moving `v1` aggregate branch. Breaking
changes bump to `v2`; consumers migrate deliberately, so one push can't break every
repo at once.
