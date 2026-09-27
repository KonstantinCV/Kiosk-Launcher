#!/usr/bin/env bash
# One-time setup of release signing (README, "Release signing"): creates the loader's release
# key on this machine and, if the GitHub CLI is installed and logged in, stores it in the
# repository's Actions secrets so CI uploads a signed app-release.
#
# Usage: scripts/setup-release-signing.sh [keystore path]   (default: ~/kiosk-loader-release.jks)
# The password is asked for, or taken from $LOADER_KEYSTORE_PASSWORD. It is never put on a
# command line. Set LOADER_REPO=owner/name to store the secrets in another repository.
set -euo pipefail

KEYSTORE=${1:-$HOME/kiosk-loader-release.jks}
ALIAS=loader
REPO=${LOADER_REPO:-KonstantinCV/Kiosk-Launcher}
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

die() {
    echo "Error: $*" >&2
    exit 1
}

command -v keytool >/dev/null || die "keytool not found. It comes with a JDK (17 or newer) and with Android Studio (see README)."
if [[ -e $KEYSTORE ]]; then
    die "$KEYSTORE already exists. The headsets trust that key: keep using it, and pass another path only to start over with a new one."
fi
mkdir -p "$(dirname "$KEYSTORE")"
KEYSTORE="$(cd "$(dirname "$KEYSTORE")" && pwd)/$(basename "$KEYSTORE")"
case $KEYSTORE in
"$REPO_ROOT"/*) die "keep the key outside the repository, e.g. ~/kiosk-loader-release.jks" ;;
esac

if [[ -z ${LOADER_KEYSTORE_PASSWORD:-} ]]; then
    read -rsp "Password for the new key (6+ characters): " LOADER_KEYSTORE_PASSWORD
    echo
    read -rsp "Same password again: " again
    echo
    [[ $LOADER_KEYSTORE_PASSWORD == "$again" ]] || die "the passwords don't match"
fi
((${#LOADER_KEYSTORE_PASSWORD} >= 6)) || die "the password needs at least 6 characters"
export LOADER_KEYSTORE_PASSWORD

# PKCS12, so the key has the keystore's password (LOADER_KEY_PASSWORD is the same)
keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Kiosk Launcher release" \
    -storepass:env LOADER_KEYSTORE_PASSWORD -keypass:env LOADER_KEYSTORE_PASSWORD >/dev/null
chmod 600 "$KEYSTORE"
fingerprint=$(keytool -list -v -keystore "$KEYSTORE" -storepass:env LOADER_KEYSTORE_PASSWORD |
    awk '/SHA256:/ { print $2; exit }')

echo "Created $KEYSTORE"
echo "Certificate SHA-256: $fingerprint"
echo

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    echo "Storing the secrets in $REPO..."
    base64 <"$KEYSTORE" | tr -d '\n' | gh secret set LOADER_KEYSTORE_BASE64 --repo "$REPO"
    printf '%s' "$LOADER_KEYSTORE_PASSWORD" | gh secret set LOADER_KEYSTORE_PASSWORD --repo "$REPO"
    printf '%s' "$ALIAS" | gh secret set LOADER_KEY_ALIAS --repo "$REPO"
    printf '%s' "$LOADER_KEYSTORE_PASSWORD" | gh secret set LOADER_KEY_PASSWORD --repo "$REPO"
    echo "Done. The next CI run uploads a signed app-release."
else
    b64="$KEYSTORE.base64.txt"
    (umask 077 && base64 <"$KEYSTORE" | tr -d '\n' >"$b64")
    cat <<EOF
The GitHub CLI isn't installed or logged in, so add the secrets by hand: in GitHub, open
$REPO > Settings > Secrets and variables > Actions > New repository secret, and add
  LOADER_KEYSTORE_BASE64    the contents of $b64
  LOADER_KEYSTORE_PASSWORD  your password
  LOADER_KEY_ALIAS          $ALIAS
  LOADER_KEY_PASSWORD       your password (the same)
Then delete $b64. (Or install gh, run 'gh auth login', delete $KEYSTORE and run this again.)
EOF
fi

cat <<EOF

Back up $KEYSTORE and its password now, in two places (e.g. a password manager and an
offline copy). Without them no later build can update the headsets.

To build a signed release locally:
  LOADER_KEYSTORE=$KEYSTORE LOADER_KEY_ALIAS=$ALIAS \\
  LOADER_KEYSTORE_PASSWORD=... LOADER_KEY_PASSWORD=... ./gradlew assembleRelease
EOF
