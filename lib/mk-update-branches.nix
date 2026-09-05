# Generates the `update-branches` orchestrator package.
#   pinSchema        : pypi | github | github-npm | github-pnpm | github-yarn | github-asset | version-only
#   branchOwnedFiles : files update-version mutates (diffed, added, committed per branch)
#   versionOverrides : map of raw upstream version -> canonical version, for upstreams whose tag numbering doesn't sort right (e.g. { "0.1.405-beta" = "0.1.40.5-beta"; }). The canonical form drives sorting/branch naming/the pin's version field; the raw form remains what update-version fetches.
#   versionCanon     : list of `sed -E` expressions applied in order to each raw version to derive its canonical form, for a tag-numbering scheme too general to enumerate in versionOverrides (e.g. every 0.1.XXX-beta hotfix -> 0.1.XX.X-beta). A matching versionOverrides entry takes precedence over these rules.
#   minVersionComponents : fewest dot-separated numeric components a tag may have and still be tracked (default 3, i.e. X.Y.Z only). Lower it for upstreams with short version tags (e.g. bare datestamps like 20260711162202).
{ pkgs, source, pinSchema, branchOwnedFiles ? [ "pin.nix" "flake.lock" ], extraHashes ? [ ], versionOverrides ? { }, versionCanon ? [ ], minVersionComponents ? 3 }:
assert builtins.elem minVersionComponents [ 1 2 3 ];
pkgs.writeShellApplication {
  name = "update-branches";
  # VERSION_OVERRIDES is a JSON string (quotes/braces) consumed via jq at runtime; the generated export trips SC2089/SC2090 (false positive).
  excludeShellChecks = [ "SC2089" "SC2090" ];
  runtimeInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
  runtimeEnv = {
    SOURCE_TYPE = source.type;
    PYPI_NAME = source.pname or "";
    PYPI_FORMAT = source.format or "sdist";
    GH_OWNER = source.owner or "";
    GH_REPO = source.repo or "";
    GH_TAG_PREFIX = source.tagPrefix or "";
    PIN_SCHEMA = pinSchema;
    BRANCH_OWNED_FILES = pkgs.lib.concatStringsSep " " branchOwnedFiles;
    EXTRA_HASHES = builtins.toJSON extraHashes;
    VERSION_OVERRIDES = builtins.toJSON versionOverrides;
    VERSION_CANON = pkgs.lib.concatStringsSep "\n" versionCanon;
    MIN_VERSION_COMPONENTS = toString minVersionComponents;
    CASCADE_PY = "${../scripts/cascade.py}";
  };
  text = ''exec ${../scripts/update-branches-core.sh} "$@"'';
}
