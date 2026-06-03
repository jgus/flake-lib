# Generates a `revalidate-hash` package: build the flake, and if a fixed-output
# (vendor) hash mismatches, read nix's "got:" hash and rewrite the pin field.
# For manifest-style flakes (e.g. caddy) whose hash can't be prefetched — the
# bespoke part (resolving what to pin) stays in the consumer; the hash dance is shared.
{ pkgs, buildAttr, hashField ? "hash" }:
pkgs.writeShellApplication {
  name = "revalidate-hash";
  # The default HASH_FIELD value "hash" collides with the `hash` shell builtin, so
  # writeShellApplication's generated `HASH_FIELD=hash` trips SC2209 (false positive).
  excludeShellChecks = [ "SC2209" ];
  runtimeEnv = {
    BUILD_ATTR = buildAttr;
    HASH_FIELD = hashField;
  };
  text = ''exec ${../scripts/revalidate-build-hash.sh} "$@"'';
}
