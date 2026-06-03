# Generates the `update-branches` orchestrator package. The logic lives in
# ../scripts/update-branches-core.sh; this injects the per-flake spec as env vars.
#   pinSchema        : pypi | github | github-npm | github-yarn (placeholder pin shape)
#   branchOwnedFiles : files update-version mutates (diffed, added, committed per branch)
{ pkgs, source, pinSchema, branchOwnedFiles ? [ "pin.nix" "flake.lock" ] }:
pkgs.writeShellApplication {
  name = "update-branches";
  runtimeEnv = {
    SOURCE_TYPE = source.type;
    PYPI_NAME = source.pname or "";
    GH_OWNER = source.owner or "";
    GH_REPO = source.repo or "";
    PIN_SCHEMA = pinSchema;
    BRANCH_OWNED_FILES = pkgs.lib.concatStringsSep " " branchOwnedFiles;
  };
  text = ''exec ${../scripts/update-branches-core.sh} "$@"'';
}
