# Pinned Linux kernel source for patch development and verification.
#
# Fetches torvalds/linux at a specific tag from GitHub with a fixed NAR hash,
# ensuring reproducible builds. The hash is verified by Nix on every fetch.
#
# To update to a new kernel version:
#   1. Change `rev` to the new tag (e.g., "v6.13")
#   2. Set `hash = ""` (empty string)
#   3. Run `nix build .#patch-check-ath9k` — Nix will error with the correct hash
#   4. Paste the correct hash back
#
# Or compute the hash directly:
#   nix-prefetch-github torvalds linux --rev v6.12
#
{ fetchFromGitHub }:

fetchFromGitHub {
  owner = "torvalds";
  repo = "linux";

  # Linux v6.12 — latest LTS at time of patch development.
  rev = "v6.12";

  # NAR hash of the source tree at this revision.
  # First build will fail with the correct hash — paste it here.
  hash = "sha256-49t94CaLdkxrmxG9Wie+p1wk6VNhraawR0vOjoFR3bY=";
}
