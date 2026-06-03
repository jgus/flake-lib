# Generates the `update-version` package. The logic lives in ../scripts/update-version.sh;
# this only injects the per-flake spec as env vars.
#   hashMode     : "prefetch" (default) or "build-failure" (vendor hashes that can't be prefetched)
#   extraHashes  : extra pin field names whose values the artifactHook emits (e.g. [ "npmDepsHash" ])
#   artifactHook : consumer script (path) that regenerates vendored files + prints name=value extra hashes
#   siblings     : sibling-cascade specs (needs python3+packaging, added below)
{ pkgs
, source
, buildAttr
, siblings ? [ ]
, hashMode ? "prefetch"
, extraHashes ? [ ]
, artifactHook ? null
}:
pkgs.writeShellApplication {
  name = "update-version";
  # EXTRA_HASHES / SIBLINGS are JSON strings (quotes/brackets) consumed via jq at
  # runtime; writeShellApplication's generated export trips SC2089/SC2090 (false positive).
  excludeShellChecks = [ "SC2089" "SC2090" ];
  runtimeInputs = pkgs.lib.optional (siblings != [ ]) (pkgs.python3.withPackages (p: [ p.packaging ]));
  runtimeEnv = {
    SOURCE_TYPE = source.type;
    PYPI_NAME = source.pname or "";
    PYPI_FORMAT = source.format or "sdist";
    GH_OWNER = source.owner or "";
    GH_REPO = source.repo or "";
    GITLAB_OWNER = source.owner or "";
    GITLAB_REPO = source.repo or "";
    BUILD_ATTR = buildAttr;
    HASH_MODE = hashMode;
    EXTRA_HASHES = builtins.toJSON extraHashes;
    ARTIFACT_HOOK = if artifactHook == null then "" else "${artifactHook}";
    SIBLINGS = builtins.toJSON siblings;
    CASCADE_PY = "${../scripts/cascade.py}";
  };
  text = ''exec ${../scripts/update-version.sh} "$@"'';
}
