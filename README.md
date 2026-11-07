# brave-nix

Nix package for the Brave browser (stable, x86_64-linux), repackaged from
the `.deb` Brave publishes. The packaging is derived from the retired
nixpkgs `brave` package.

## Use

```nix
inputs.brave = {
  url = "github:cmm/brave-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then apply `brave.overlays.default`, or use `brave.packages.x86_64-linux.brave`.

## Authentication

The `.deb` carries no signature of its own. `sources/` holds the checksum file
Brave signs for each GitHub release, plus its signature; the package takes its
version and hash from that file and verifies the signature before unpacking.

The daily update job (`update.py`) cross-checks that checksum against Brave's
separately signed apt repository and only ever moves to a newer version. It
should only ever change `sources/`.

`keys/checksums-release.asc` verifies the GitHub checksums and
`keys/apt-release.asc` the apt metadata. Compare their fingerprints
(`gpg --show-keys keys/*.asc`) with <https://brave.com/signing-keys/>. When
Brave starts signing with a key not in `keys/`, the update job fails until
the key is added by hand.
