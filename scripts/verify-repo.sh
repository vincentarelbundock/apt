#!/usr/bin/env bash
# Install from the built tree before it is published.
#
# This is the check that matters: an apt repository can be perfectly
# well-formed as a directory and still be unusable because the Release file is
# signed by a key apt does not have, or because a Packages stanza points at a
# Filename that is not there. Both fail here, against file://, using the same
# apt code path that runs over HTTP.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
public="$root/public"

[ -d "$public/dists/stable" ] || { echo "no built repository in public/" >&2; exit 1; }

arch="$(dpkg --print-architecture)"

if [ ! -f "$public/dists/stable/main/binary-$arch/Packages" ]; then
  echo "no index for this machine's architecture ($arch); nothing to verify here"
  exit 0
fi

if [ -f "$public/vab-archive-keyring.gpg" ]; then
  sudo install -m644 "$public/vab-archive-keyring.gpg" \
    /usr/share/keyrings/vab-archive-keyring.gpg
  entry="deb [arch=$arch signed-by=/usr/share/keyrings/vab-archive-keyring.gpg] file://$public stable main"
else
  echo "warning: unsigned repository, verifying with [trusted=yes]" >&2
  entry="deb [arch=$arch trusted=yes] file://$public stable main"
fi

echo "$entry" | sudo tee /etc/apt/sources.list.d/vab-verify.list >/dev/null

# Only this repository, so a name that also exists in Debian cannot silently
# satisfy the install and make the check pass for the wrong reason.
sudo apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/vab-verify.list \
                    -o Dir::Etc::sourceparts=/dev/null \
                    -o APT::Get::List-Cleanup=0

status=0
while read -r pkg; do
  [ -n "$pkg" ] || continue
  echo "=== $pkg"
  if ! sudo apt-get install -y --no-install-recommends "$pkg"; then
    echo "::error::$pkg failed to install from the built repository"
    status=1
    continue
  fi
  # Every package here ships exactly one command named after itself.
  if ! "$pkg" --version; then
    echo "::error::$pkg installed but does not run"
    status=1
  fi
  sudo apt-get remove -y "$pkg" >/dev/null
done < <(awk '/^Package: / { print $2 }' "$public/dists/stable/main/binary-$arch/Packages" | sort -u)

sudo rm -f /etc/apt/sources.list.d/vab-verify.list
exit "$status"
