# Generates the `update-branches` orchestrator package. The logic lives in
# ../scripts/update-branches-core.sh; this injects the per-flake spec as env vars.
#   pinSchema        : pypi | github | github-npm | github-yarn | version-only (placeholder pin shape)
#   branchOwnedFiles : files update-version mutates (diffed, added, committed per branch)
#   versionOverrides : map of raw upstream version -> canonical version, for upstreams whose tag numbering doesn't sort right (e.g. { "0.1.405-beta" = "0.1.40.5-beta"; }). The canonical form drives sorting/branch naming/the pin's version field; the raw form remains what update-version fetches.
{ pkgs, source, pinSchema, branchOwnedFiles ? [ "pin.nix" "flake.lock" ], versionOverrides ? { }, excludePrereleases ? false }:
pkgs.writeShellApplication {
  name = "update-branches";
  # VERSION_OVERRIDES is a JSON string (quotes/braces) consumed via jq at runtime; the generated export trips SC2089/SC2090 (false positive).
  excludeShellChecks = [ "SC2089" "SC2090" ];
  runtimeEnv = {
    SOURCE_TYPE = source.type;
    PYPI_NAME = source.pname or "";
    PYPI_FORMAT = source.format or "sdist";
    GH_OWNER = source.owner or "";
    GH_REPO = source.repo or "";
    PIN_SCHEMA = pinSchema;
    BRANCH_OWNED_FILES = pkgs.lib.concatStringsSep " " branchOwnedFiles;
    VERSION_OVERRIDES = builtins.toJSON versionOverrides;
    EXCLUDE_PRERELEASES = pkgs.lib.optionalString excludePrereleases "1";
  };
  text = ''exec ${../scripts/update-branches-core.sh} "$@"'';
}
