#!/usr/bin/env python3
"""Advance sources/ to Brave's newest stable Linux release.

Run from the repository root with sqv on PATH (`nix run .#update`).
Exits 0 when already current, when the new release's signed checksum is not
published yet, or after updating; exits nonzero on any authentication or
consistency failure. After an update, writes `previous` and `version` to
$GITHUB_OUTPUT when that is set.
"""

import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime

APT = "https://brave-browser-apt-release.s3.brave.com"
GITHUB = "https://github.com/brave/brave-browser/releases/download"
PACKAGE = "brave-browser"
ARCH = "amd64"
CHECKSUM = f"sources/{PACKAGE}_{ARCH}.deb.sha256"
SIGNATURE = CHECKSUM + ".asc"
APT_KEYS = "keys/apt-release.asc"
CHECKSUM_KEYS = "keys/checksums-release.asc"
# The apt metadata has no Valid-Until, so a mirror could replay an old signed
# snapshot indefinitely. Stable releases have come at most ~12 days apart.
STALE_AFTER = timedelta(days=21)

# Must agree with the pattern in package.nix.
CHECKSUM_RE = re.compile(
    rb"([0-9a-f]{64})  (%s_([0-9]+(?:\.[0-9]+)*)_%s\.deb)\n?"
    % (PACKAGE.encode(), ARCH.encode())
)


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def verify(keyring, signature, data):
    with tempfile.TemporaryDirectory() as tmp:
        sig_path = os.path.join(tmp, "sig")
        data_path = os.path.join(tmp, "data")
        with open(sig_path, "wb") as f:
            f.write(signature)
        with open(data_path, "wb") as f:
            f.write(data)
        subprocess.run(
            ["sqv", "--keyring", keyring, sig_path, data_path],
            check=True,
            stdout=subprocess.DEVNULL,
        )


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def parse_checksum(data):
    match = CHECKSUM_RE.fullmatch(data)
    if not match:
        sys.exit(f"unexpected checksum file contents: {data!r}")
    return match.group(1).decode(), match.group(3).decode()


def deb822(text):
    """Parse deb822 stanzas into dicts; continuation lines are kept."""
    for stanza in text.split("\n\n"):
        fields = {}
        key = None
        for line in stanza.splitlines():
            if line[:1] in (" ", "\t") and key:
                fields[key] += "\n" + line.strip()
            elif ":" in line:
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        if fields:
            yield fields


def apt_latest():
    """Return (signed date, newest version, its SHA256) from the apt repo."""
    release = fetch(f"{APT}/dists/stable/Release")
    verify(APT_KEYS, fetch(f"{APT}/dists/stable/Release.gpg"), release)
    (fields,) = deb822(release.decode())
    date = parsedate_to_datetime(fields["Date"])

    index_path = f"main/binary-{ARCH}/Packages"
    for line in fields["SHA256"].splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == index_path:
            index_sha256, index_size = parts[0], int(parts[1])
            break
    else:
        sys.exit(f"{index_path} is not listed in the signed Release file")

    index = fetch(f"{APT}/dists/stable/{index_path}")
    if len(index) != index_size or hashlib.sha256(index).hexdigest() != index_sha256:
        sys.exit(f"{index_path} does not match the signed Release file")

    candidates = [
        (version_key(s["Version"]), s["Version"], s["SHA256"])
        for s in deb822(index.decode())
        if s.get("Package") == PACKAGE
    ]
    if not candidates:
        sys.exit(f"no {PACKAGE} in {index_path}")
    _, version, sha256 = max(candidates)
    return date, version, sha256


def main():
    if not os.path.isfile(CHECKSUM):
        sys.exit("run from the repository root")
    with open(CHECKSUM, "rb") as f:
        _, current = parse_checksum(f.read())

    date, latest, apt_sha256 = apt_latest()
    if datetime.now(timezone.utc) - date > STALE_AFTER:
        sys.exit(f"signed apt metadata is dated {date}; frozen or replayed repository?")

    if version_key(latest) < version_key(current):
        print(
            f"::warning::apt offers {latest}, older than pinned {current}; keeping {current}"
        )
        return
    if latest == current:
        print(f"up to date at {current}")
        return

    name = f"{PACKAGE}_{latest}_{ARCH}.deb"
    try:
        checksum = fetch(f"{GITHUB}/v{latest}/{name}.sha256")
        signature = fetch(f"{GITHUB}/v{latest}/{name}.sha256.asc")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"{latest} is in apt, but its signed checksum is not on GitHub yet")
            return
        raise

    verify(CHECKSUM_KEYS, signature, checksum)
    github_sha256, github_version = parse_checksum(checksum)
    if github_version != latest:
        sys.exit(f"signed checksum names {github_version}, expected {latest}")
    if github_sha256 != apt_sha256:
        sys.exit(f"{name}: GitHub checksum {github_sha256} != apt {apt_sha256}")

    with open(CHECKSUM, "wb") as f:
        f.write(checksum)
    with open(SIGNATURE, "wb") as f:
        f.write(signature)
    print(f"{current} -> {latest}")

    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as f:
            f.write(f"previous={current}\nversion={latest}\n")


if __name__ == "__main__":
    main()
