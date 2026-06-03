# Generates the `update-version` package. The actual logic lives in
# ../scripts/update-version.sh; this only injects the per-flake spec as env vars.
# python3+packaging is added only when sibling cascades are configured (the
# cascade resolver needs it, and it can't be expressed as a nix-shell shebang).
{ pkgs, source, buildAttr, siblings ? [ ] }:
pkgs.writeShellApplication {
  name = "update-version";
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
    SIBLINGS = builtins.toJSON siblings;
    CASCADE_PY = "${../scripts/cascade.py}";
  };
  text = ''exec ${../scripts/update-version.sh} "$@"'';
}
