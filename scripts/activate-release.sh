
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/www/cloudarchitects"
RELEASES="$BASE/releases"
CURRENT="$BASE/current"

RELEASE="${1:?Usage: activate-release.sh RELEASE_NAME}"
DOMAIN="cloud-architects.duckdns.org"

# Only accept safe release identifiers.
[[ "$RELEASE" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  echo "Invalid release name"
  exit 1
}

TARGET="$RELEASES/$RELEASE"

[[ -d "$TARGET" && -s "$TARGET/index.html" ]] || {
  echo "Release is missing or invalid: $TARGET"
  exit 1
}

# The previous release must remain available for rollback.
PREVIOUS=""
if [[ -L "$CURRENT" ]]; then
  PREVIOUS=$(readlink -f "$CURRENT")
fi

# Atomically replace the current symlink.
ln -s "$TARGET" "$BASE/.current-next"
mv -Tf "$BASE/.current-next" "$CURRENT"

echo "Activated release: $RELEASE"

# Check Nginx locally using the correct virtual host.
if curl --fail --silent --show-error \
  --max-time 10 \
  -H "Host: $DOMAIN" \
  http://127.0.0.1/ \
  -o /dev/null; then
  echo "Health check passed."
else
  echo "Health check failed."

  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
    ln -s "$PREVIOUS" "$BASE/.current-next"
    mv -Tf "$BASE/.current-next" "$CURRENT"
    echo "Rolled back to: $PREVIOUS"
  else
    echo "No previous release available."
  fi

  exit 1
fi
