# Generates a `revalidate-hash` package that rewrites a flake's fixed-output hash pin from a build-time hash mismatch.
{ pkgs, buildAttr, hashField ? "hash" }:
pkgs.writeShellApplication {
  name = "revalidate-hash";
  # The default HASH_FIELD value "hash" collides with the `hash` shell builtin, so writeShellApplication's generated `HASH_FIELD=hash` trips SC2209 (false positive).
  excludeShellChecks = [ "SC2209" ];
  runtimeEnv = {
    BUILD_ATTR = buildAttr;
    HASH_FIELD = hashField;
  };
  text = ''exec ${../scripts/revalidate-build-hash.sh} "$@"'';
}
