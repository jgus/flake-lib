# High-level helper: a simple PyPI leaf flake collapses to one call.
#   flake-lib.lib.mkLeafFlake {
#     inherit nixpkgs flake-utils;
#     source  = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };
#     package = { attr = "iso639-lang"; description = "..."; };
#     pin     = import ./pin.nix;
#   }
# Returns the full flake-utils eachDefaultSystem outputs set.
{ mkPypiPackage, mkUpdateVersion, mkUpdateBranches }:
{ nixpkgs
, flake-utils
, source
, package
, pin
, branches ? true
, siblings ? [ ]
, branchOwnedFiles ? [ "pin.nix" "flake.lock" ]
}:
flake-utils.lib.eachDefaultSystem (system:
  let
    pkgs = import nixpkgs { inherit system; };
    pkg = mkPypiPackage { inherit pkgs source package pin; };
    pinSchema = if source.type == "pypi" then "pypi" else "github";
    update-version = mkUpdateVersion { inherit pkgs source siblings; buildAttr = package.attr; };
    update-branches = mkUpdateBranches { inherit pkgs source pinSchema branchOwnedFiles; };
  in
  {
    packages =
      {
        ${package.attr} = pkg;
        default = pkg;
        inherit update-version;
      }
      // pkgs.lib.optionalAttrs branches { inherit update-branches; };
  })
