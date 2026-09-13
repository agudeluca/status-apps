#!/bin/bash
# One-command install:
#
#   curl -fsSL https://raw.githubusercontent.com/agudeluca/status-apps/main/scripts/install.sh | bash
#
# Clones the repo, builds the app and puts it in /Applications. Re-running it updates an
# existing install; `--uninstall` removes the app, its stored state and the checkout.
#
# It builds on the machine instead of shipping a binary. The bundle is signed ad-hoc, and an
# ad-hoc bundle that arrives over the network carries a quarantine attribute — macOS would
# refuse to open it until the attribute was stripped by hand. A local build has nothing to
# work around.
#
# Run from a checkout (`./scripts/install.sh`) it builds that working tree instead of cloning.
set -euo pipefail

REPO="${STATUS_APPS_REPO:-https://github.com/agudeluca/status-apps.git}"
BRANCH="${STATUS_APPS_BRANCH:-main}"
MANAGED_SRC="$HOME/.local/share/status-apps"
SRC="${STATUS_APPS_SRC:-$MANAGED_SRC}"
APP="StatusApps.app"
STATE="$HOME/Library/Application Support/StatusApps"

die() { echo "Error: $*" >&2; exit 1; }

# Working from a checkout: build it rather than cloning a second copy. An explicit
# STATUS_APPS_SRC wins, so the clone path stays reachable from inside a checkout.
LOCAL=0
if [ -z "${STATUS_APPS_SRC:-}" ]; then
  self="${BASH_SOURCE[0]:-}"
  if [ -n "$self" ] && [ -f "$self" ]; then
    here="$(cd "$(dirname "$self")/.." && pwd)"
    if [ -f "$here/Package.swift" ]; then
      SRC="$here"
      LOCAL=1
    fi
  fi
fi

# STATUS_APPS_DEST exists so an install can be exercised without touching the real one.
DEST="${STATUS_APPS_DEST:-}"
if [ -z "$DEST" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"  # accounts without admin rights
fi

# Every location is tried on uninstall: an account that cannot write to /Applications
# installed to ~/Applications instead.
uninstall() {
  pkill -x StatusApps 2>/dev/null || true
  rm -rf "/Applications/$APP" "$HOME/Applications/$APP" "${DEST:?}/$APP" "$STATE"
  # Only ever the checkout this script made itself; a clone kept anywhere else is someone's work.
  if [ "$SRC" = "$MANAGED_SRC" ] && [ -d "$SRC" ]; then
    rm -rf "$SRC"
    echo "==> Removed the app, its stored state and $SRC"
  else
    echo "==> Removed the app and its stored state. The checkout in $SRC is untouched."
  fi
}

case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (expected --uninstall)" ;;
esac

echo "==> Checking requirements"
[ "$(uname -s)" = "Darwin" ] || die "Status Apps is a macOS app."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 13 ] || die "macOS 13 or later required (found $(sw_vers -productVersion))."
command -v git >/dev/null 2>&1 || die "git not found."
# The stubs in /usr/bin exist before the command line tools do, so check that they run.
if ! xcode-select -p >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
  die "Swift toolchain not found. Install the Xcode command line tools:

    xcode-select --install

  then run this again."
fi

if [ "$LOCAL" = 1 ]; then
  echo "==> Building the checkout in $SRC"
elif [ -d "$SRC/.git" ]; then
  echo "==> Updating $SRC"
  # Fetching by URL rather than by remote name keeps this working if the clone predates a
  # change of STATUS_APPS_REPO. The checkout is disposable, so a hard reset is safe.
  git -C "$SRC" fetch --depth 1 "$REPO" "$BRANCH"
  git -C "$SRC" reset --hard FETCH_HEAD
else
  echo "==> Cloning into $SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
fi

"$SRC/scripts/bundle.sh"

echo "==> Installing to $DEST"
mkdir -p "$DEST"
pkill -x StatusApps 2>/dev/null || true
rm -rf "${DEST:?}/$APP"
cp -R "$SRC/$APP" "$DEST/"
open "$DEST/$APP"

echo "==> Done. Look for ⇅ in the menu bar."
