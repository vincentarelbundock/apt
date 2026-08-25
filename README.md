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

Generate a signing key that does nothing else. It should be a repository key,
not a personal identity, and it should never be the key used for anything
else:

```sh
gpg --batch --pinentry-mode loopback --passphrase "" \
  --quick-generate-key "vab apt repository <vincent@arelbundock.com>" \
  rsa4096 sign never
```

`never` means the key does not expire, which matters here: an expired archive
key makes `apt update` fail for everyone with no obvious cause. Then export
the private half and add it as a repository secret:

```sh
gpg --armor --export-secret-keys "vab apt repository" | gh secret set APT_GPG_PRIVATE_KEY --repo vincentarelbundock/apt
```

If the key has a passphrase, set `APT_GPG_PASSPHRASE` too. The build exports
the public half to `vab-archive-keyring.gpg` (binary, for `signed-by=`) and
`KEY.asc` (armored), so users never fetch it from a keyserver.

Back the private key up somewhere offline. Losing it is recoverable but
noisy: every user has to install a new keyring before `apt update` works
again.

## Testing locally

`scripts/build-repo.sh` needs `jq`, `gh`, `nfpm` and `apt-ftparchive`, so it is
easiest to run in a container:

```sh
docker run --rm -it -v "$PWD:/repo" -w /repo -e GH_TOKEN debian:stable-slim \
  sh -c 'apt-get update && apt-get install -y curl jq gpg apt-utils sudo && ...'
```

`scripts/verify-repo.sh` then installs every package from the built tree over
`file://`, which is the same apt code path used over HTTP. CI runs both.
