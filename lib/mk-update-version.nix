# Generates the `update-version` package.
#   hashMode     : "prefetch" (default) or "build-failure" (vendor hashes that can't be prefetched)
#   extraHashes  : extra pin field names whose values the artifactHook emits (e.g. [ "npmDepsHash" ])
#   artifactHook : consumer script (path) that regenerates vendored files + prints name=value extra hashes
#   siblings     : sibling-cascade specs
{ pkgs
, source
, buildAttr
, siblings ? [ ]
, siblingRefsInPin ? false
, hashMode ? "prefetch"
, extraHashes ? [ ]
, buildFailureHash ? if hashMode == "build-failure" then "sourceHash" else null
, artifactHook ? null
, verification ? if buildFailureHash == null then "evaluate" else "build"
}:
assert builtins.elem verification [ "evaluate" "build" ];
assert buildFailureHash == null || verification == "build";
pkgs.writeShellApplication {
  name = "update-version";
  # EXTRA_HASHES / SIBLINGS are JSON strings (quotes/brackets) consumed via jq at runtime (SC2089/SC2090); GH_ASSET/GH_TAG carry a literal ${version}/${tag} token the script substitutes at runtime, intentionally single-quoted (SC2016). All false positives on the generated export.
  excludeShellChecks = [ "SC2016" "SC2089" "SC2090" ];
  runtimeInputs = pkgs.lib.optional (siblings != [ ]) (pkgs.python3.withPackages (p: [ p.packaging ]));
  runtimeEnv = {
    SOURCE_TYPE = source.type;
    PYPI_NAME = source.pname or "";
    PYPI_FORMAT = source.format or "sdist";
    GH_OWNER = source.owner or "";
    GH_REPO = source.repo or "";
    GH_TAG_PREFIX = source.tagPrefix or "";
    GH_TRACK = source.track or "release"; # release (Releases API) | tag (latest version git tag) | commit (default-branch HEAD -> 0-unstable-DATE)
    GH_BRANCH = source.branch or ""; # commit-tracking: branch to follow (default: repo's default branch)
    GH_FETCH_SUBMODULES = if (source.fetchSubmodules or false) then "1" else ""; # hash the tree with submodules (src must set fetchSubmodules = true)
    GH_ASSET = source.asset or ""; # github-release-asset: filename template, tokens ${version} and ${tag}
    GH_TAG = source.tag or ""; # github-release-asset: tag template, token ${version} (default v${version})
    GITLAB_OWNER = source.owner or "";
    GITLAB_REPO = source.repo or "";
    GITLAB_TRACK = source.track or "commit"; # release (tags -> X.Y.Z) | commit (master HEAD -> 0-unstable-DATE)
    HF_REPO = if source.type == "huggingface" then source.repo else "";
    HF_REVISION = source.revision or "main";
    HF_FILES = builtins.toJSON (source.files or [ ]);
    BUILD_ATTR = buildAttr;
    HASH_MODE = hashMode;
    EXTRA_HASHES = builtins.toJSON extraHashes;
    PIN_HASHES = builtins.toJSON (pkgs.lib.unique (extraHashes ++ pkgs.lib.optional (buildFailureHash != null && buildFailureHash != "sourceHash") buildFailureHash));
    BUILD_FAILURE_HASH = if buildFailureHash == null then "" else buildFailureHash;
    ARTIFACT_HOOK = if artifactHook == null then "" else "${artifactHook}";
    VERIFICATION = verification;
    SIBLINGS = builtins.toJSON siblings;
    SIBLING_REFS_IN_PIN = pkgs.lib.optionalString siblingRefsInPin "1";
    CASCADE_PY = "${../scripts/cascade.py}";
  };
  text = ''exec ${../scripts/update-version.sh} "$@"'';
}
