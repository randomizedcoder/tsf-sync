# Pin build-host-only tools to the native package set so they hit the
# binary cache instead of being rebuilt from source.
#
# Problem: `import nixpkgs { crossSystem = ...; }` taints the derivation
# hashes of ALL packages — even tools that only run on the build host.
# Crane uses remarshal (a Python tool) to write cleaned Cargo.toml files
# during buildDepsOnly.  Under cross, remarshal gets a unique hash that
# misses the cache, pulling in ~235 other derivations (~2.3 GiB)
# that must be built from source.
#
# Fix: override build-host-only tools to use the pre-built native versions.
# These tools never execute on the target, so the native binary is correct.
{ pkgsNative }:
_final: _prev: {
  inherit (pkgsNative) remarshal;
}
