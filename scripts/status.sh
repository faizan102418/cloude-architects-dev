
#!/usr/bin/env bash
set -euo pipefail

# Production paths; override BASE for local testing.
BASE="${BASE:-/var/www/cloudarchitects}"
TEMPLATE="${TEMPLATE:-$BASE/templates/status.html}"
OUTPUT="${OUTPUT:-$BASE/live/status.html}"

# Collect server information.
SERVER_HOSTNAME=$(hostname)
UPDATED=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
UPTIME=$(uptime -p)
LOAD=$(awk '{print $1 ", " $2 ", " $3}' /proc/loadavg)

MEMORY=$(free -h | awk '/^Mem:/ {
  print $3 " / " $2
}')

DISK=$(df -h / | awk 'NR==2 {
  print $3 " / " $2 " (" $5 " used)"
}')

DISK_PERCENT=$(df -P / | awk 'NR==2 {
  gsub("%", "", $5)
  print $5
}')

# Check Nginx service status.
if systemctl is-active --quiet nginx; then
  NGINX="● ACTIVE & RUNNING"
else
  NGINX="● DOWN - WARNING"
fi

# Identify active release.
if [[ -L "$BASE/current" ]]; then
  RELEASE=$(readlink -f "$BASE/current")
else
  RELEASE="No active release"
fi

# Read recent deployment history.
if [[ -r "$BASE/deploys.log" ]]; then
  RECENT=$(tail -n 5 "$BASE/deploys.log")
else
  RECENT="No deployment history available"
fi

# Check disk health.
if (( DISK_PERCENT >= 90 )); then
  DISK_WARNING="WARNING: Disk usage is high!"
else
  DISK_WARNING="OK"
fi

# Verify the template exists.
if [[ ! -r "$TEMPLATE" ]]; then
  echo "ERROR: Status template not found: $TEMPLATE" >&2
  exit 1
fi

# Pass monitoring values to Python through environment variables.
export SERVER_HOSTNAME UPDATED UPTIME LOAD MEMORY DISK
export NGINX RELEASE RECENT DISK_WARNING TEMPLATE OUTPUT

# Render the template using Python's standard library.
python3 <<'PY'
import html
import os
import tempfile
from pathlib import Path

template_path = Path(os.environ["TEMPLATE"])
output_path = Path(os.environ["OUTPUT"])

content = template_path.read_text(encoding="utf-8")

values = {
    "HOSTNAME": os.environ["SERVER_HOSTNAME"],
    "UPDATED": os.environ["UPDATED"],
    "UPTIME": os.environ["UPTIME"],
    "LOAD": os.environ["LOAD"],
    "MEMORY": os.environ["MEMORY"],
    "DISK": os.environ["DISK"],
    "NGINX": os.environ["NGINX"],
    "RELEASE": os.environ["RELEASE"],
    "RECENT": os.environ["RECENT"],
    "DISK_WARNING": os.environ["DISK_WARNING"],
}

# Require every placeholder before rendering.
for key in values:
    placeholder = "{{" + key + "}}"

    if placeholder not in content:
        raise ValueError(
            f"Missing placeholder in template: {placeholder}"
        )

    content = content.replace(
        placeholder,
        html.escape(values[key], quote=True)
    )

# Write to a temporary file and replace atomically.
output_path.parent.mkdir(parents=True, exist_ok=True)

temporary_path = None

try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_path.parent,
        prefix=".status-",
        suffix=".tmp",
        delete=False,
    ) as temporary_file:
        temporary_path = Path(temporary_file.name)
        temporary_file.write(content)

    temporary_path.chmod(0o644)
    temporary_path.replace(output_path)

finally:
    if temporary_path is not None:
        temporary_path.unlink(missing_ok=True)

print(f"Status dashboard generated: {output_path}")
PY
