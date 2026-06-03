# Builds a PyPI-sourced python package (or application) from a pin + spec.
# Covers the simple-leaf cases: sdist+setuptools, wheel, buildPythonApplication,
# optional extra build-system / dependencies / passthru attrs.
{ pkgs, source, package, pin }:
let
  inherit (pkgs) lib;
  ps = pkgs.python3Packages;
  inherit (pin) version hash;

  kind = package.kind or "pythonPackage";
  builder = if kind == "pythonApplication" then ps.buildPythonApplication else ps.buildPythonPackage;
  format = source.format or "sdist";
  description = package.description or "";

  deps = (package.dependencies or (_: [ ])) ps;
  meta = (lib.optionalAttrs (description != "") { inherit description; }) // (package.meta or { });

  srcAttrs =
    if format == "wheel" then {
      format = "wheel";
      src = ps.fetchPypi {
        pname = source.pname;
        format = "wheel";
        python = "py3";
        inherit version hash;
      };
    } else {
      pyproject = true;
      src = ps.fetchPypi { pname = source.pname; inherit version hash; };
      build-system = (package.buildSystem or (p: [ p.setuptools ])) ps;
    };
in
builder ({
  pname = package.attr;
  inherit version;
  doCheck = false;
}
// srcAttrs
// lib.optionalAttrs (deps != [ ]) { dependencies = deps; }
// lib.optionalAttrs (meta != { }) { inherit meta; }
// (package.extra or { }))
