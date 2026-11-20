#!/bin/bash
# Sign and publish tatareka-bpjs-monitoring into the same dnf repository as tatareka-ai-klaim (so hospitals that have
# tatareka-release find both, and tatareka-ai-klaim's Recommends resolves). Uses tatareka-ai-klaim's rpm/publish.conf
# and the same signing key.
#   rpm/release.sh release   build VERSION-<YYMMDDNN>, sign, add to the repo
#   rpm/release.sh upload    publish the repo (UPLOAD_CMD from tatareka-ai-klaim/rpm/publish.conf)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
NAME=tatareka-bpjs-monitoring
KEY_UID="Tatareka AI Klaim Release Signing Key"
PUBKEY=rpm/RPM-GPG-KEY-tatareka
DIST=el9; REPO_DIR=; UPLOAD_CMD=
. "$ROOT/../tatareka-ai-klaim/rpm/publish.conf"
REPO=$REPO_DIR/tatareka-ai-klaim/$DIST
VER=$(tr -d ' \n' < VERSION)
die() { echo "release: $*" >&2; exit 1; }
fpr=$(gpg --batch --list-secret-keys --with-colons "$KEY_UID" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
command -v rpmsign >/dev/null 2>&1 || rpmsign() { nix shell nixpkgs#rpm -c rpmsign "$@"; }
command -v rpmkeys >/dev/null 2>&1 || rpmkeys() { nix shell nixpkgs#rpm -c rpmkeys "$@"; }
command -v createrepo_c >/dev/null 2>&1 || createrepo_c() { nix shell nixpkgs#createrepo_c -c createrepo_c "$@"; }

case "${1:-}" in
  release)
    [ -n "$fpr" ] || die "no signing key"
    day=$(date +%y%m%d)
    n=$( { ls "$REPO"/$NAME-$VER-$day*.noarch.rpm 2>/dev/null || true; } | sed -E "s/.*-$VER-$day([0-9]{2})\.noarch\.rpm/\1/" | sort -n | tail -1)
    rel=$day$(printf %02d $(( 10#${n:-0} + 1 )))
    rpm/build.sh "$VER" "$rel" >/dev/null
    rpm=rpm/dist/$NAME-$VER-$rel.noarch.rpm; [ -f "$rpm" ] || die "build failed"
    rpmsign --addsign --define "_gpg_name $fpr" "$rpm" >/dev/null 2>&1
    kdb=$(mktemp -d); rpmkeys --dbpath "$kdb" --import "$PUBKEY"
    rpmkeys --dbpath "$kdb" -K "$rpm" | grep -q "signatures OK" || { rm -rf "$kdb"; die "signature check failed on $rpm"; }
    rm -rf "$kdb"
    cp "$rpm" "$REPO/"
    createrepo_c --update -q "$REPO"
    rm -f "$REPO/repodata/repomd.xml.asc"
    gpg --batch --yes --local-user "$fpr" --armor --detach-sign "$REPO/repodata/repomd.xml"
    echo "released $NAME-$VER-$rel -> $REPO"
    ;;
  upload)
    [ -n "$UPLOAD_CMD" ] || die "no UPLOAD_CMD in tatareka-ai-klaim/rpm/publish.conf"
    REPO_DIR=$REPO_DIR bash -c "$UPLOAD_CMD"
    ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
