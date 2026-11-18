
#!/usr/bin/env bash
set -euo pipefail

BASE="/var/www/cloudarchitects"
RELEASES="$BASE/releases"
CURRENT="$BASE/current"
LOG="$BASE/deploys.log"

ACTOR="${1:?Usage: rollback.sh ACTOR}"

# Prevent rollback during a deployment.
exec 9>"$BASE/.deploy.lock"
flock -n 9 || {
  echo "Another deployment or rollback is running"
  exit 1
}

CURRENT_RELEASE=$(readlink -f "$CURRENT")
CURRENT_NAME=$(basename "$CURRENT_RELEASE")

# Find the release immediately before the current one.
mapfile -t RELEASE_LIST < <(
  find "$RELEASES" -mindepth 1 -maxdepth 1 \
    -type d -name 'release-*' -printf '%f\n' | sort
)

PREVIOUS=""
for ((i=0; i<${#RELEASE_LIST[@]}; i++)); do
  if [[ "${RELEASE_LIST[$i]}" == "$CURRENT_NAME" && i -gt 0 ]]; then
    PREVIOUS="$RELEASES/${RELEASE_LIST[$((i-1))]}"
    break
  fi
done

if [[ -z "$PREVIOUS" ]]; then
  echo "No older release available for rollback"
  exit 1
fi

# Atomically switch the website.
NEXT="$BASE/.rollback-next-$$"
trap 'rm -f "$NEXT"' EXIT

ln -s "$PREVIOUS" "$NEXT"
mv -Tf "$NEXT" "$CURRENT"

printf '%s | ROLLBACK | %s | %s\n' \
  "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
  "$ACTOR" "$(basename "$PREVIOUS")" >> "$LOG"

echo "Rollback successful: $(basename "$PREVIOUS")"
