#!/usr/bin/env bash
# Assemble the whole apt repository into public/, ready to be deployed to
# GitHub Pages.
#
# Nothing binary is ever committed to this repository. Every .deb is fetched
# from the upstream project's GitHub release at build time, so the source of
# truth stays in each project and this repository holds only the description
# of how to serve them.
#
# The output layout is a normal flat-ish Debian repository:
#
#   public/pool/main/<name>_<version>_<arch>.deb
#   public/dists/stable/main/binary-<arch>/{Packages,Packages.gz}
#   public/dists/stable/{Release,InRelease,Release.gpg}
#   public/vab-archive-keyring.gpg
#
# Signing happens only when APT_GPG_PRIVATE_KEY is set. Without it the
# repository is still usable, but every client has to opt out of verification
# with `[trusted=yes]`, so an unsigned build prints a loud warning.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

public="$root/public"
work="$root/.work"
manifest="$root/projects.json"

# `stable` is a single suite covering every Debian and Ubuntu release. These
# are statically linked-ish CLI tools whose only dependency is libc, so there
# is nothing to fork per distribution; if that ever stops being true, this is
# where a second suite would go.
SUITE=stable
COMPONENT=main
ORIGIN="Vincent Arel-Bundock"
LABEL="vab"

rm -rf "$public" "$work"
mkdir -p "$public/pool/$COMPONENT" "$work"

for tool in jq gh nfpm apt-ftparchive; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

arches_seen=()

note() { printf '  %s\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; }

track_arch() {
  local a="$1" seen
  for seen in ${arches_seen[@]+"${arches_seen[@]}"}; do
    [ "$seen" = "$a" ] && return 0
  done
  arches_seen+=("$a")
}

project_count="$(jq '.projects | length' "$manifest")"
for i in $(seq 0 $((project_count - 1))); do
  name="$(jq -r ".projects[$i].name" "$manifest")"
  repo="$(jq -r ".projects[$i].repo" "$manifest")"
  deb_pattern="$(jq -r ".projects[$i].deb_pattern // empty" "$manifest")"
  nfpm_template="$(jq -r ".projects[$i].nfpm // empty" "$manifest")"

  # The latest non-draft, non-prerelease tag. A prerelease reaching users who
  # asked for a stable apt suite would be a surprise, so it is skipped.
  tag="$(gh release list --repo "$repo" --limit 20 \
          --json tagName,isDraft,isPrerelease \
          -q '[.[] | select(.isDraft == false and .isPrerelease == false)][0].tagName')"
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    warn "$name: no published release; skipping"
    continue
  fi
  version="${tag#v}"
  echo "$name $version ($repo)"

  assets="$work/$name-assets.txt"
  gh release view "$tag" --repo "$repo" --json assets -q '.assets[].name' > "$assets"

  while read -r arch triple; do
    [ -n "$arch" ] || continue
    outdir="$work/$name-$arch"
    rm -rf "$outdir"; mkdir -p "$outdir"

    if [ -n "$deb_pattern" ]; then
      # Serve upstream's own package. The pattern carries a literal ARCH
      # placeholder so one line in projects.json covers every architecture.
      pattern="${deb_pattern//ARCH/$arch}"
      if ! grep -qE "^${pattern//\*/.*}$" "$assets"; then
        warn "$name: no asset matching $pattern in $tag; skipping $arch"
        continue
      fi
      gh release download "$tag" --repo "$repo" \
        --pattern "$pattern" --dir "$outdir" --clobber
      found="$(find "$outdir" -maxdepth 1 -name '*.deb' -print -quit)"
      [ -n "$found" ] || { warn "$name: download produced no .deb for $arch"; continue; }
      cp "$found" "$public/pool/$COMPONENT/"
      note "$arch: upstream $(basename "$found")"
    else
      # Build the package here from the released binary.
      asset="$name-$triple.tar.xz"
      if ! grep -qx "$asset" "$assets"; then
        warn "$name: $tag publishes no $asset; skipping $arch"
        continue
      fi
      gh release download "$tag" --repo "$repo" \
        --pattern "$asset" --dir "$outdir" --clobber
      mkdir -p "$outdir/unpack"
      tar -xJf "$outdir/$asset" -C "$outdir/unpack" --strip-components=1
      [ -f "$outdir/unpack/$name" ] || { warn "$name: no $name binary inside $asset"; continue; }
      chmod 755 "$outdir/unpack/$name"

      # nfpm expands environment variables in scalar fields but not in
      # `contents[].src`, so the binary is staged at the fixed path each
      # template names rather than passed in as a variable.
      rm -rf "$work/staging"; mkdir -p "$work/staging"
      install -m755 "$outdir/unpack/$name" "$work/staging/$name"
      PKG_VERSION="$version" PKG_ARCH="$arch" \
        nfpm package --packager deb --config "$root/$nfpm_template" \
          --target "$public/pool/$COMPONENT/" >/dev/null
      note "$arch: built ${name}_${version}_${arch}.deb from $asset"
    fi

    track_arch "$arch"
  done < <(jq -r ".projects[$i].arches | to_entries[] | \"\(.key) \(.value)\"" "$manifest")
done

if [ ${#arches_seen[@]} -eq 0 ]; then
  echo "no packages were collected; refusing to publish an empty repository" >&2
  exit 1
fi

echo
echo "Indexing: ${arches_seen[*]}"

# apt-ftparchive wants paths relative to the repository root, because that is
# what ends up in each Packages stanza's Filename: field and what apt appends
# to the URL from sources.list.
cd "$public"
for arch in "${arches_seen[@]}"; do
  dir="dists/$SUITE/$COMPONENT/binary-$arch"
  mkdir -p "$dir"
  apt-ftparchive --arch "$arch" packages "pool/$COMPONENT" > "$dir/Packages"
  gzip -9 -c "$dir/Packages" > "$dir/Packages.gz"
  echo "  $dir/Packages ($(grep -c '^Package: ' "$dir/Packages") packages)"
done

apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=$ORIGIN" \
  -o "APT::FTPArchive::Release::Label=$LABEL" \
  -o "APT::FTPArchive::Release::Suite=$SUITE" \
  -o "APT::FTPArchive::Release::Codename=$SUITE" \
  -o "APT::FTPArchive::Release::Components=$COMPONENT" \
  -o "APT::FTPArchive::Release::Architectures=${arches_seen[*]}" \
  -o "APT::FTPArchive::Release::Description=CLI tools by Vincent Arel-Bundock" \
  release "dists/$SUITE" > "dists/$SUITE/Release"

if [ -n "${APT_GPG_PRIVATE_KEY:-}" ]; then
  export GNUPGHOME="$work/gnupg"
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  printf '%s' "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
  # What to sign with. The key in APT_GPG_PRIVATE_KEY may be a dedicated
  # archive key exported whole, or a signing subkey of a personal key exported
  # on its own. The second shape is the better one, because it keeps the
  # primary secret out of CI: a leaked subkey costs one revoked subkey, a
  # leaked primary costs the whole identity. It also means the primary secret
  # is absent here, so gpg has to be pointed at that exact subkey with a
  # trailing "!" rather than being left to choose for itself.
  #
  # In --with-colons output, field 12 is a key's own capabilities ("s" for
  # signing) and field 15 is "+" when its secret material is actually present.
  # A subkey that was not exported has neither.
  colons="$(gpg --list-secret-keys --with-colons)"
  signkey="$(printf %s "$colons" |
    awk -F: '$1 == "ssb" && $12 ~ /s/ && $15 == "+" { print $5 "!"; exit }')"
  if [ -z "$signkey" ]; then
    signkey="$(printf %s "$colons" |
      awk -F: '$1 == "sec" && $12 ~ /s/ && $15 == "+" { print $5; exit }')"
  fi
  if [ -z "$signkey" ]; then
    echo "APT_GPG_PRIVATE_KEY imported no key that can sign" >&2
    exit 1
  fi

  # The keyring users install is the whole public key, primary and subkeys, so
  # it keeps working when the signing subkey is rotated.
  primary="$(printf %s "$colons" | awk -F: '$1 == "fpr" { print $10; exit }')"

  # An expired archive key makes `apt update` fail for every user, with an
  # error that does not obviously say why, and extending the expiry upstream
  # does not help anyone who already installed the keyring file. So an expiry
  # is worth being loud about well before it lands.
  expiry="$(printf %s "$colons" |
    awk -F: -v k="${signkey%!}" \
      '($1 == "sec" || $1 == "ssb") && $5 == k { print $7; exit }')"
  if [ -n "$expiry" ] && [ "$expiry" != "0" ]; then
    days=$(( (expiry - $(date +%s)) / 86400 ))
    if [ "$days" -lt 0 ]; then
      echo "signing key ${signkey%!} expired $(( -days )) days ago; publishing would break apt update for every user" >&2
      exit 1
    elif [ "$days" -lt 90 ]; then
      warn "signing key ${signkey%!} expires in $days days ($(date -u -d "@$expiry" +%Y-%m-%d)). Extend it, and note that users who already installed the keyring will need the refreshed file."
    fi
  fi

  gpgopts=(--batch --yes --quiet --local-user "$signkey")
  if [ -n "${APT_GPG_PASSPHRASE:-}" ]; then
    gpgopts+=(--pinentry-mode loopback --passphrase "$APT_GPG_PASSPHRASE")
  fi

  # Both forms, because both are still in use: InRelease is the inline-signed
  # file modern apt prefers, Release.gpg the detached signature beside Release.
  gpg "${gpgopts[@]}" --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
  gpg "${gpgopts[@]}" --armor --detach-sign -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"

  # The binary form is what `signed-by=` in a sources.list entry wants.
  gpg --export "$primary" > "$public/vab-archive-keyring.gpg"
  gpg --export --armor "$primary" > "$public/KEY.asc"
  echo "  signed with $signkey"
else
  cat >&2 <<'UNSIGNED'
  warning: APT_GPG_PRIVATE_KEY is not set, so dists/stable/Release is unsigned.
  Clients will have to use [trusted=yes], which disables the only check that
  proves the packages came from this repository. See README.md for how to
  generate a signing key and add it as a repository secret.
UNSIGNED
fi

cd "$root"

# The landing page's install instructions depend on whether this build
# actually signed the Release file. Writing them here rather than in
# site/index.html is the point: a hardcoded `signed-by=` snippet on an
# unsigned repository sends every reader into an `apt update` failure, and a
# hardcoded `trusted=yes` snippet teaches people to disable verification long
# after it started working.
if [ -f "$public/vab-archive-keyring.gpg" ]; then
  cat > "$work/install.html" <<'HTML'
<h2>Add the repository</h2>
<pre><code>curl -fsSL https://vincentarelbundock.github.io/apt/vab-archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/vab-archive-keyring.gpg &gt; /dev/null

echo "deb [signed-by=/usr/share/keyrings/vab-archive-keyring.gpg] \
https://vincentarelbundock.github.io/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/vab.list &gt; /dev/null

sudo apt-get update</code></pre>
HTML
else
  cat > "$work/install.html" <<'HTML'
<h2>Add the repository</h2>
<p class="warn"><strong>This repository is not signed yet.</strong> The entry
below carries <code>trusted=yes</code>, which tells apt to accept the packages
without verifying where they came from. If you would rather not do that,
download the <code>.deb</code> you want from the project's own releases page
instead.</p>
<pre><code>echo "deb [trusted=yes] https://vincentarelbundock.github.io/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/vab.list &gt; /dev/null

sudo apt-get update</code></pre>
HTML
fi

# Splice it in, then drop the placeholder line itself.
awk -v f="$work/install.html" '
  /<!--INSTALL-SNIPPET-->/ { while ((getline line < f) > 0) print line; next }
  { print }
' site/index.html > "$public/index.html"

rm -rf "$work"

echo
echo "Repository assembled in public/"
find "$public/pool" -name '*.deb' -printf '  %f\n' | sort
