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

`sources/` holds the checksum file Brave publishes with each GitHub release and
its detached signature. The package takes its version and `.deb` hash from that
file, and the build verifies the signature against `keys/checksums-release.asc`
before unpacking anything.

`nix run .#update` (run daily by CI) advances `sources/` only if all of these hold:

- the newest stable version comes from the apt repository's `Release` file,
  signed by a key in `keys/apt-release.asc`, through the `Packages` index it
  authenticates;
- that version is newer than the pinned one, and the signed `Release` is less
  than 21 days old;
- the GitHub checksum file is signed by a key in `keys/checksums-release.asc`
  and names exactly that version's `.deb`;
- the GitHub and apt SHA256 of the `.deb` agree.

Keys, as published at <https://brave.com/signing-keys/>:

| File | Fingerprints |
|---|---|
| `keys/checksums-release.asc` ("Brave Checksums Release") | `10A714FCA3C829A605E686A5C479D18E038EAF42`, `7FE68A2E3754FA350A45F0AB68E5C22615F0E249`, `B840107020F8BED83CF7696DEDC0814C91A8144D` |
| `keys/apt-release.asc` ("Brave Linux Release") | `DBF1A116C220B8C7164F98230686B78420038257`, `47D32A74E9A9E013A4B4926C68D513D36A73CD96`, `B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0` |

When Brave rotates keys, the update job fails until `keys/` is updated by hand.
