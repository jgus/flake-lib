let
  mkPypiPackage = import ./mk-pypi-package.nix;
  mkUpdateVersion = import ./mk-update-version.nix;
  mkUpdateBranches = import ./mk-update-branches.nix;
  mkRevalidateHash = import ./mk-revalidate-hash.nix;
  mkJsDepsHook = import ./mk-js-deps-hook.nix;
  mkComposedHook = import ./mk-composed-hook.nix;
  mkLeafFlake = import ./mk-leaf-flake.nix { inherit mkPypiPackage mkUpdateVersion mkUpdateBranches; };

  warnIfNewerMajor = { pkgs, name, lib ? pkgs.lib }:
    let
      parts = builtins.match "([^0-9]*)([0-9]+)(.*)" name;
      prefix = builtins.elemAt parts 0;
      current = lib.toInt (builtins.elemAt parts 1);
      suffix = builtins.elemAt parts 2;
      majorOf = n: let m = builtins.match "${prefix}([0-9]+)${suffix}" n; in if m == null then null else lib.toInt (builtins.head m);
      newest = builtins.foldl' (a: b: if b > a then b else a) current
        (builtins.filter (x: x != null) (map majorOf (builtins.attrNames pkgs)));
    in
    lib.warnIf (newest > current)
      "warnIfNewerMajor: ${name} is pinned, but nixpkgs has ${prefix}${toString newest}${suffix}. Consider migrating."
      pkgs.${name};
in
{
  inherit mkPypiPackage mkUpdateVersion mkUpdateBranches mkRevalidateHash mkJsDepsHook mkComposedHook mkLeafFlake warnIfNewerMajor;
}
