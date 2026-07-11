# Builds a PyPI-sourced python package (or application) from a pin + spec.
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
      # Universal wheel. fetchPypi's `dist` (URL path segment) and `python` (filename tag) both default to py2.py3; a py3-none-any wheel needs both set to py3, else the path 404s. Platform-specific wheels aren't covered here.
      src = ps.fetchPypi {
        pname = source.pname;
        format = "wheel";
        dist = "py3";
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
