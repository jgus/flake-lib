# Composes several flake-lib artifactHooks into one executable usable in a single `artifactHook` slot.
{ pkgs
, hooks
}:
let inherit (pkgs) lib;
in
lib.getExe (pkgs.writeShellApplication {
  name = "composed-hook";
  text = lib.concatMapStringsSep "\n" (h: ''"${h}"'') hooks;
})
