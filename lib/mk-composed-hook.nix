# Composes several flake-lib artifactHooks into one. Runs each in turn (inheriting mkUpdateVersion's NEW_REV / NEW_VERSION / FLAKE_ROOT / GH_OWNER / GH_REPO env) and concatenates their `name=value` stdout, so a flake can mix a shared hook (e.g. mkJsDepsHook) with its own bespoke one. Returns an executable path.
#
#   hooks : list of executable hook paths (each prints its own name=value lines)
{ pkgs
, hooks
}:
let inherit (pkgs) lib;
in
lib.getExe (pkgs.writeShellApplication {
  name = "composed-hook";
  text = lib.concatMapStringsSep "\n" (h: ''"${h}"'') hooks;
})
