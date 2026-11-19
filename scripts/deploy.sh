
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/www/cloudarchitects"
UPLOAD="$BASE/upload"
RELEASES="$BASE/releases"
CURRENT="$BASE/current"
LOG="$BASE/deploys.log"

BIN="$BASE/bin"
TEMPLATES="$BASE/templates"

# Prevent simultaneous deployments.
LOCK_FILE="$BASE/.deploy.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "ERROR: Another deployment is already running"
  exit 1
fi

# Validate workflow arguments.
COMMIT="${1:?Usage: deploy.sh COMMIT ACTOR}"
ACTOR="${2:?Usage: deploy.sh COMMIT ACTOR}"

[[ "$COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] || {
  echo "ERROR: Invalid commit SHA"
  exit 1
}

[[ "$ACTOR" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  echo "ERROR: Invalid actor"
  exit 1
}

# --------------------------------------------------
# 1. Validate all uploaded files before deployment.
# --------------------------------------------------

echo "Validating uploaded deployment files..."

[[ -s "$UPLOAD/site/index.html" ]] || {
  echo "ERROR: No staged website found" >&2
  exit 1
}

REQUIRED_FILES=(
  "$UPLOAD/scripts/status.sh"
  "$UPLOAD/scripts/traffic-report.sh"
  "$UPLOAD/live/status.html"
  "$UPLOAD/live/report.html"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -s "$file" ]]; then
    echo "ERROR: Required file missing: $file" >&2
    exit 1
  fi
done

# Validate monitoring script syntax.
bash -n "$UPLOAD/scripts/status.sh"
bash -n "$UPLOAD/scripts/traffic-report.sh"

# Validate required dashboard placeholders.
python3 - "$UPLOAD/live/status.html" "$UPLOAD/live/report.html" <<'PY'
import sys
from pathlib import Path

templates = {
    Path(sys.argv[1]): {
        "HOSTNAME",
        "UPDATED",
        "UPTIME",
        "LOAD",
        "MEMORY",
        "DISK",
        "NGINX",
        "RELEASE",
        "RECENT",
        "DISK_WARNING",
    },
    Path(sys.argv[2]): {
        "UPDATED",
        "TOTAL",
        "ERRORS_404",
        "TOP_PAGES",
        "TOP_IPS",
        "TOP_MISSING",
    },
}

for path, required in templates.items():
    content = path.read_text(encoding="utf-8")

    missing = [
        key for key in sorted(required)
        if "{{" + key + "}}" not in content
    ]

    if missing:
        raise SystemExit(
            f"ERROR: {path} missing placeholders: "
            + ", ".join(missing)
        )

    print(f"Template validated: {path}")
PY

echo "All deployment files validated."

# --------------------------------------------------
# 2. Prepare the new website release.
# --------------------------------------------------

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEPLOY_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

RELEASE="release-${TIMESTAMP}-${COMMIT:0:12}"
TARGET="$RELEASES/$RELEASE"

if [[ -e "$TARGET" ]]; then
  echo "ERROR: Release already exists"
  exit 1
fi

mkdir -p "$RELEASES" "$TARGET"

# Copy staged website into the new release.
cp -a "$UPLOAD/site/." "$TARGET/"

# --------------------------------------------------
# 3. Add deployment version information.
# --------------------------------------------------

while IFS= read -r -d '' page; do

  COMMIT="$COMMIT" \
  ACTOR="$ACTOR" \
  DEPLOY_TIME="$DEPLOY_TIME" \
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

marker = (
    f"<!-- DEPLOY_COMMIT: "
    f"{os.environ['COMMIT']} -->"
)

if marker not in content:
    content = marker + "\n" + content

page.write_text(content, encoding="utf-8")
PY

done < <(
  find "$TARGET" -type f -name '*.html' -print0
)

# --------------------------------------------------
# 4. Remember the previous release.
# --------------------------------------------------

PREVIOUS=""

if [[ -L "$CURRENT" ]]; then
  PREVIOUS=$(readlink -f "$CURRENT")
fi

# --------------------------------------------------
# 5. Install monitoring scripts and templates.
# --------------------------------------------------

echo "Installing monitoring scripts and templates..."

mkdir -p "$BIN" "$TEMPLATES" "$BASE/live"

install -m 755 \
  "$UPLOAD/scripts/status.sh" \
  "$BIN/status.sh"

install -m 755 \
  "$UPLOAD/scripts/traffic-report.sh" \
  "$BIN/traffic-report.sh"

install -m 644 \
  "$UPLOAD/live/status.html" \
  "$TEMPLATES/status.html"

install -m 644 \
  "$UPLOAD/live/report.html" \
  "$TEMPLATES/report.html"

echo "Monitoring scripts and templates installed."

# --------------------------------------------------
# 6. Activate the new release atomically.
# --------------------------------------------------

NEXT_LINK="$BASE/.current-next-$$"
CRON_FILE=""

cleanup() {
  rm -f -- "$NEXT_LINK"

  if [[ -n "$CRON_FILE" ]]; then
    rm -f -- "$CRON_FILE"
  fi
}

trap cleanup EXIT

ln -s "$TARGET" "$NEXT_LINK"
mv -Tf "$NEXT_LINK" "$CURRENT"

echo "Activated release: $RELEASE"

# --------------------------------------------------
# 7. Record previous release for rollback.
# --------------------------------------------------

if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
  printf '%s\n' "$PREVIOUS" \
    > "$BASE/.previous-release"
fi

# --------------------------------------------------
# 8. Record deployment history.
# --------------------------------------------------

printf '%s | DEPLOY | %s | %s | %s\n' \
  "$DEPLOY_TIME" \
  "$COMMIT" \
  "$ACTOR" \
  "$RELEASE" >> "$LOG"

# --------------------------------------------------
# 9. Configure monitoring cron jobs.
# --------------------------------------------------

echo "Configuring monitoring cron jobs..."

CRON_FILE=$(mktemp)

# Keep unrelated cron jobs and remove old monitoring
# entries before installing the current versions.
crontab -l 2>/dev/null |
  grep -v -E \
    '/var/www/cloudarchitects/bin/(status|traffic-report)\.sh' \
  > "$CRON_FILE" || true

cat >> "$CRON_FILE" <<'CRON'
* * * * * /usr/bin/bash /var/www/cloudarchitects/bin/status.sh >> /var/www/cloudarchitects/status-cron.log 2>&1
*/5 * * * * /usr/bin/bash /var/www/cloudarchitects/bin/traffic-report.sh >> /var/www/cloudarchitects/traffic-cron.log 2>&1
CRON

crontab "$CRON_FILE"

echo "Monitoring cron jobs configured."

# --------------------------------------------------
# 10. Generate monitoring dashboards immediately.
# --------------------------------------------------

echo "Generating monitoring dashboards..."

if ! /usr/bin/bash "$BIN/status.sh"; then
  echo "WARNING: Status dashboard generation failed" >&2
fi

if ! /usr/bin/bash "$BIN/traffic-report.sh"; then
  echo "WARNING: Traffic dashboard generation failed" >&2
fi

echo "Monitoring generation attempted."

# --------------------------------------------------
# 11. Clean up older website releases.
# --------------------------------------------------

mapfile -t OLD_RELEASES < <(
  find "$RELEASES" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release-*' \
    -printf '%f\n' |
    sort -r |
    tail -n +6
)

for old in "${OLD_RELEASES[@]}"; do

  OLD_PATH="$RELEASES/$old"

  # Never delete the active release.
  if [[ "$OLD_PATH" == "$(readlink -f "$CURRENT")" ]]; then
    continue
  fi

  # Never delete the immediately previous release.
  if [[ -n "$PREVIOUS" && "$OLD_PATH" == "$PREVIOUS" ]]; then
    continue
  fi

  rm -rf -- "$OLD_PATH"

done

# --------------------------------------------------
# 12. Deployment summary.
# --------------------------------------------------

echo
echo "======================================"
echo "Deployment successful"
echo "======================================"
echo "Release: $RELEASE"
echo "Commit: $COMMIT"
echo "Actor: $ACTOR"
echo "Time: $DEPLOY_TIME"
echo
echo "Monitoring templates:"
echo "  $TEMPLATES/status.html"
echo "  $TEMPLATES/report.html"
echo
echo "Generated dashboards:"
echo "  $BASE/live/status.html"
echo "  $BASE/live/report.html"
echo "======================================"
