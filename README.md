# vab apt repository

An APT repository for a few of my command-line tools, served from GitHub
Pages. Install instructions: <https://vincentarelbundock.github.io/apt>.

Nothing binary is committed here. On every run, `scripts/build-repo.sh` reads
`projects.json`, fetches each project's latest stable release from GitHub,
assembles and signs a Debian repository, and the workflow deploys it to
Pages.

## Adding a package

Add an entry to `projects.json`, in one of two forms:

- **`deb_pattern`** — the project's releases already include a `.deb`. Give
  the asset name with a literal `ARCH` placeholder. Preferred, because the
  project's own dependency declarations are kept.
- **`nfpm`** — the project only publishes cargo-dist tarballs. Write a
  template under `packaging/` and point `nfpm` at it.

Push to `main`; the workflow rebuilds and redeploys. After that, new upstream
versions appear via the nightly cron, or within minutes if the project's
release workflow sends a `repository_dispatch` of type `upstream-release`.
Drafts and prereleases are skipped.

## Signing

Builds are signed with the signing subkey of the archive key
`D87F 0902 9A47 8448 132D 1E1A 0266 1C78 C999 67CA` (no passphrase). The
`APT_GPG_PRIVATE_KEY` actions secret holds that subkey alone (exported with a
trailing `!`); the primary stays in the offline backup. Without the secret,
the build publishes unsigned with a loud warning.

## Testing locally

`scripts/build-repo.sh` needs `jq`, `gh`, `nfpm` and `apt-ftparchive`;
`scripts/verify-repo.sh` then installs every package from the built tree over
`file://`, the same apt code path used over HTTP. CI runs both.
