# vab apt repository

An APT repository for a few of my command-line tools, served from GitHub Pages
at <https://vincentarelbundock.github.io/apt>.

```sh
curl -fsSL https://vincentarelbundock.github.io/apt/vab-archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/vab-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/vab-archive-keyring.gpg] \
https://vincentarelbundock.github.io/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/vab.list > /dev/null

sudo apt-get update && sudo apt-get install calepin
```

## How it works

Nothing binary lives in this repository. On every run,
`scripts/build-repo.sh` reads `projects.json`, fetches each project's latest
stable release from GitHub, assembles a Debian repository under `public/`, and
the workflow deploys that tree to Pages. The source of truth for every package
stays in the project that produced it.

A project can appear in `projects.json` in one of two forms:

- **`deb_pattern`** names a `.deb` the project's own release already
  publishes. Those exact bytes are served, so a project that declares its own
  dependencies keeps them. This is the preferred form.
- **`nfpm`** names a template under `packaging/`, for a project that publishes
  only cargo-dist tarballs. The `.deb` is built here from the released binary.
  Moving a project to the first form later is a one-line change.

Rebuilds are triggered by a nightly cron, by a `repository_dispatch` of type
`upstream-release` (which a project's release workflow can send to make a new
version appear within minutes), and by pushes that change the description
here.

Only stable releases are served: drafts and prereleases are skipped.

## Adding a package

Add an entry to `projects.json`. If the project publishes its own `.deb`, give
it a `deb_pattern` with a literal `ARCH` placeholder. Otherwise write a
template in `packaging/` and point `nfpm` at it. Push to `main`; the workflow
rebuilds and redeploys.

## Signing

The repository is signed when the `APT_GPG_PRIVATE_KEY` secret is set, and
builds unsigned with a loud warning when it is not. Unsigned means every user
has to add `[trusted=yes]`, which turns off the only check that proves the
packages came from here, so it is worth setting up once.

Whatever key is used, **export only a signing subkey to CI, never the primary
secret**. A leaked subkey costs one revoked subkey and a refreshed keyring; a
leaked primary costs the whole identity. The build handles either shape, but
it prints which key it signed with so the difference is visible in the log.

### Using a personal key

If you already have a personal GPG key, add a signing subkey to it and export
that:

```sh
# The primary key's fingerprint.
fpr=$(gpg --list-keys --with-colons vincent@arelbundock.com \
        | awk -F: '/^fpr:/ { print $10; exit }')

# A signing subkey that does nothing else and does not expire.
gpg --quick-add-key "$fpr" rsa4096 sign never

# The subkey id, and the secret half of that subkey ALONE. The trailing "!"
# is what restricts the export to exactly this subkey.
sub=$(gpg --list-keys --with-colons "$fpr" \
        | awk -F: '$1 == "sub" && $12 ~ /s/ { print $5 }' | tail -1)
gpg --armor --export-secret-subkeys "${sub}!" \
  | gh secret set APT_GPG_PRIVATE_KEY --repo vincentarelbundock/apt
```

The primary secret never leaves your machine. If the subkey is ever exposed,
`gpg --quick-revoke-key` it, add a new one, update the secret, and rerun the
workflow; users pick up the refreshed keyring on their next `apt update` only
if they reinstall the keyring file, so plan on announcing it.

### Using a dedicated archive key

If you would rather keep this separate from your identity, generate a key that
does nothing else:

```sh
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "vab apt repository <vincent@arelbundock.com>" \
  rsa4096 sign never

gpg --armor --export-secret-keys "vab apt repository" \
  | gh secret set APT_GPG_PRIVATE_KEY --repo vincentarelbundock/apt
```

Back the private half up offline. Losing it is recoverable but noisy: every
user has to install a new keyring before `apt update` works again.

### Passphrases and expiry

If the key has a passphrase, set `APT_GPG_PASSPHRASE` as a second secret; the
build passes it through to gpg.

`never` in the commands above is deliberate. An expired archive key makes
`apt update` fail for everyone with an error that does not obviously name the
cause, and extending the expiry here does not help anyone who already
installed the keyring file. The build refuses to publish with an expired
signing key and warns for 90 days beforehand.

The public half is exported to `vab-archive-keyring.gpg` (binary, for
`signed-by=`) and `KEY.asc` (armored) on every build, so users never fetch it
from a keyserver. Both carry the whole public key including subkeys, so
rotating the signing subkey does not invalidate a keyring a user already has.

## Testing locally

`scripts/build-repo.sh` needs `jq`, `gh`, `nfpm` and `apt-ftparchive`, so it is
easiest to run in a container:

```sh
docker run --rm -it -v "$PWD:/repo" -w /repo -e GH_TOKEN debian:stable-slim \
  sh -c 'apt-get update && apt-get install -y curl jq gpg apt-utils sudo && ...'
```

`scripts/verify-repo.sh` then installs every package from the built tree over
`file://`, which is the same apt code path used over HTTP. CI runs both.
