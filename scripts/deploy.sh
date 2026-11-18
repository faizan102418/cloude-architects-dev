
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/www/cloudarchitects"
UPLOAD="$BASE/upload"
RELEASES="$BASE/releases"
CURRENT="$BASE/current"
LOG="$BASE/deploys.log"

# Prevent simultaneous deployments on the EC2 server.
LOCK_FILE="$BASE/.deploy.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "ERROR: Another deployment is already running"
  exit 1
fi

COMMIT="${1:?Usage: deploy.sh COMMIT ACTOR}"
ACTOR="${2:?Usage: deploy.sh COMMIT ACTOR}"

# Validate input supplied by the workflow.
[[ "$COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] || {
  echo "ERROR: Invalid commit SHA"
  exit 1
}

[[ "$ACTOR" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  echo "ERROR: Invalid actor"
  exit 1
}

[[ -s "$UPLOAD/site/index.html" ]] || {
  echo "ERROR: No staged website found"
  exit 1
}

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEPLOY_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
RELEASE="release-${TIMESTAMP}-${COMMIT:0:12}"
TARGET="$RELEASES/$RELEASE"

if [[ -e "$TARGET" ]]; then
  echo "ERROR: Release already exists"
  exit 1
fi

mkdir -p "$TARGET"

# Copy staged website into the new release.
cp -a "$UPLOAD/site/." "$TARGET/"

# Replace version placeholders in every HTML page.
while IFS= read -r -d '' page; do
  COMMIT="$COMMIT" ACTOR="$ACTOR" DEPLOY_TIME="$DEPLOY_TIME" \
    python3 - "$page" <<'PY'
import os
import sys
from pathlib import Path

page = Path(sys.argv[1])
content = page.read_text(encoding="utf-8")

version = (
    f"Commit: {os.environ['COMMIT']} | "
    f"Actor: {os.environ['ACTOR']} | "
    f"Time: {os.environ['DEPLOY_TIME']}"
)

content = content.replace("__VERSION__", version)

# Add a version marker even if the HTML has no placeholder.
marker = f"<!-- DEPLOY_COMMIT: {os.environ['COMMIT']} -->"

if marker not in content:
    content = marker + "\n" + content

page.write_text(content, encoding="utf-8")
PY
done < <(find "$TARGET" -type f -name '*.html' -print0)

# Remember the previously active release for rollback.
PREVIOUS=""

if [[ -L "$CURRENT" ]]; then
  PREVIOUS=$(readlink -f "$CURRENT")
fi

# Atomically activate the new release.
NEXT_LINK="$BASE/.current-next-$$"

trap 'rm -f "$NEXT_LINK"' EXIT

ln -s "$TARGET" "$NEXT_LINK"
mv -Tf "$NEXT_LINK" "$CURRENT"

# Record previous release for emergency rollback.
if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
  printf '%s\n' "$PREVIOUS" > "$BASE/.previous-release"
fi

# Record deployment history.
printf '%s | DEPLOY | %s | %s | %s\n' \
  "$DEPLOY_TIME" "$COMMIT" "$ACTOR" "$RELEASE" >> "$LOG"

# Keep the five newest timestamped releases.
mapfile -t OLD_RELEASES < <(
  find "$RELEASES" -mindepth 1 -maxdepth 1 \
    -type d -name 'release-*' -printf '%f\n' |
    sort -r |
    tail -n +6
)

for old in "${OLD_RELEASES[@]}"; do
  OLD_PATH="$RELEASES/$old"

  # Never remove the active or immediately previous release.
  if [[ "$OLD_PATH" == "$(readlink -f "$CURRENT")" ]]; then
    continue
  fi

  if [[ -n "$PREVIOUS" && "$OLD_PATH" == "$PREVIOUS" ]]; then
    continue
  fi

  rm -rf -- "$OLD_PATH"
done


# A13: Automatically install monitoring scripts.
echo "Installing monitoring scripts..."

BIN="$BASE/bin"
mkdir -p "$BIN" "$BASE/live"

install -m 755 "$UPLOAD/scripts/status.sh" "$BIN/status.sh"
install -m 755 "$UPLOAD/scripts/traffic-report.sh" "$BIN/traffic-report.sh"

# Configure cron without duplicating existing monitoring jobs.
CRON_FILE=$(mktemp)
trap 'rm -f "$NEXT_LINK" "$CRON_FILE"' EXIT

crontab -l 2>/dev/null |
  grep -v -E '/var/www/cloudarchitects/bin/(status|traffic-report)\.sh' \
  > "$CRON_FILE" || true

cat >> "$CRON_FILE" <<'CRON'
* * * * * /usr/bin/bash /var/www/cloudarchitects/bin/status.sh >> /var/www/cloudarchitects/status-cron.log 2>&1
*/5 * * * * /usr/bin/bash /var/www/cloudarchitects/bin/traffic-report.sh >> /var/www/cloudarchitects/traffic-cron.log 2>&1
CRON

crontab "$CRON_FILE"

# Generate both monitoring pages immediately.
/usr/bin/bash "$BIN/status.sh"
/usr/bin/bash "$BIN/traffic-report.sh"

echo "Monitoring installation completed"


echo "Deployment successful"
echo "Release: $RELEASE"
echo "Commit: $COMMIT"
echo "Actor: $ACTOR"
echo "Time: $DEPLOY_TIME"

