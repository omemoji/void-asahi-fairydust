#!/bin/sh
# Build linux-asahi-fairydust in a void-packages checkout, sign an xbps binary
# repository under ./dist/<arch>/, and (optionally) publish it to the orphan
# branch "repository-<arch>" which is served to users via raw.githubusercontent.
#
# The -dbg package is intentionally NOT distributed (the official Void repos
# don't ship debug packages in the main repository either).
#
# Usage:
#   ./mkrepo.sh              # build + sign into ./dist/aarch64 only
#   PUBLISH=1 ./mkrepo.sh    # also force-push it to the repository-aarch64 branch
#
# Overridable via environment:
#   VOIDPKGS   path to the void-packages checkout (default: ~/github/omemoji/void-packages)
#   KEYDIR     dir holding privkey.pem            (default: ~/.config/void-asahi-fairydust)
#   SIGNEDBY   signature identity string
#   XBPS_PASSPHRASE  passphrase for the (encrypted) signing key; prompted if unset
set -eu

VOIDPKGS="${VOIDPKGS:-$HOME/github/omemoji/void-packages}"
KEYDIR="${KEYDIR:-$HOME/.config/void-asahi-fairydust}"
PRIVKEY="$KEYDIR/privkey.pem"
SIGNEDBY="${SIGNEDBY:-omemoji <me@omemoji.com>}"

PKG=linux-asahi-fairydust
ARCH=aarch64
BRANCH="repository-$ARCH"
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
DIST="$HERE/dist/$ARCH"

# --- sanity checks ---------------------------------------------------------
[ -x "$VOIDPKGS/xbps-src" ] || { echo "error: xbps-src not found under VOIDPKGS=$VOIDPKGS" >&2; exit 1; }
[ -f "$PRIVKEY" ] || { echo "error: signing key not found: $PRIVKEY" >&2; exit 1; }
command -v xbps-rindex >/dev/null || { echo "error: xbps-rindex not in PATH" >&2; exit 1; }

# --- signing passphrase ----------------------------------------------------
# If the key is passphrase-protected, read it once so the two signing steps
# below don't prompt twice. xbps-rindex picks it up from XBPS_PASSPHRASE.
if grep -q ENCRYPTED "$PRIVKEY" && [ -z "${XBPS_PASSPHRASE:-}" ]; then
	printf "Passphrase for signing key: " >&2
	stty -echo 2>/dev/null || true
	read XBPS_PASSPHRASE
	stty echo 2>/dev/null || true
	echo >&2
	export XBPS_PASSPHRASE
fi

# --- 1. sync vendored template (keep git copy = what we build) -------------
echo ">> syncing vendored srcpkg from $VOIDPKGS"
rm -rf "$HERE/srcpkg/$PKG"
cp -a "$VOIDPKGS/srcpkgs/$PKG" "$HERE/srcpkg/"

# --- 2. build --------------------------------------------------------------
echo ">> building $PKG in $VOIDPKGS"
( cd "$VOIDPKGS" && ./xbps-src pkg "$PKG" )

# --- 3. collect artifacts (main + headers only; no -dbg) -------------------
binroot="$VOIDPKGS/hostdir/binpkgs/$PKG"
echo ">> assembling repository in $DIST"
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$binroot"/${PKG}-*.xbps "$DIST"/   # -dbg lives in debug/ and is excluded

# --- 4. index + sign -------------------------------------------------------
echo ">> indexing"
xbps-rindex -a "$DIST"/*.xbps
echo ">> signing repository metadata"
xbps-rindex --sign --signedby "$SIGNEDBY" --privkey "$PRIVKEY" "$DIST"
echo ">> signing packages"
xbps-rindex --sign-pkg --privkey "$PRIVKEY" "$DIST"/*.xbps

echo
echo "Repository ready: $DIST"
ls -1 "$DIST"

# --- 5. publish to the orphan branch ---------------------------------------
# Done in a throwaway clone so the working tree/branch you are on is untouched.
# The branch is recreated from scratch each time (single commit, no history
# bloat from large binaries).
if [ "${PUBLISH:-0}" = 1 ]; then
	remote=$(git -C "$HERE" remote get-url origin)
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	echo ">> publishing to branch $BRANCH on $remote"
	git clone -q "$HERE" "$tmp/pub"
	cd "$tmp/pub"
	git checkout -q --orphan "$BRANCH"
	git rm -rqf . >/dev/null 2>&1 || true   # empty the branch (no source files, no history)
	cp "$DIST"/* .
	git add -A
	git -c user.name="mkrepo" -c user.email="mkrepo@localhost" \
		commit -q -m "Update $ARCH repository ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
	git push -qf "$remote" "$BRANCH"
	echo ">> published. Users install from:"
	echo "   repository=https://raw.githubusercontent.com/${remote#*github.com[:/]}/$BRANCH" \
		| sed 's/\.git//'
else
	cat <<EOF

Not published (set PUBLISH=1 to push). To publish manually, force-push the
contents of $DIST to the '$BRANCH' branch (orphan, single commit).

Users install from:
  repository=https://raw.githubusercontent.com/omemoji/void-asahi-fairydust/$BRANCH
EOF
fi
