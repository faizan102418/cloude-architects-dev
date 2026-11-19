
#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-/var/www/cloudarchitects}"
LOG="${LOG:-/var/log/nginx/cloudarchitects-access.log}"
TEMPLATE="${TEMPLATE:-$BASE/templates/report.html}"
OUTPUT="${OUTPUT:-$BASE/live/report.html}"

if [[ ! -r "$LOG" ]]; then
  echo "ERROR: Cannot read Nginx access log: $LOG" >&2
  exit 1
fi

if [[ ! -r "$TEMPLATE" ]]; then
  echo "ERROR: Traffic template not found: $TEMPLATE" >&2
  exit 1
fi

python3 - "$LOG" "$TEMPLATE" "$OUTPUT" <<'PY'
import html
import ipaddress
import re
import sys
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

log_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

total = 0
errors_404 = 0
pages = Counter()
ips = Counter()
missing = Counter()

pattern = re.compile(
    r'^(\S+) .*?"[A-Z]+ (\S+) [^"]+" (\d{3}) '
)

def mask_ip(address):
    try:
        ip = ipaddress.ip_address(address)

        if isinstance(ip, ipaddress.IPv4Address):
            parts = address.split(".")
            return ".".join(parts[:3]) + ".xxx"

        # Hide the last 80 bits of an IPv6 address.
        network = ipaddress.ip_network(
            f"{address}/48",
            strict=False
        )
        return str(network.network_address) + "/48"

    except ValueError:
        return "Unknown client"

with log_path.open(encoding="utf-8", errors="replace") as log:
    for line in log:
        match = pattern.search(line)

        if not match:
            continue

        ip, path, status = match.groups()

        # Ignore monitoring dashboard requests.
        if path.split("?")[0].startswith("/live/"):
            continue

        total += 1
        pages[path] += 1
        ips[mask_ip(ip)] += 1

        if status == "404":
            errors_404 += 1
            missing[path] += 1

def top_five(counter):
    if not counter:
        return '<li class="report-empty">No data yet</li>'

    items = []

    for name, count in counter.most_common(5):
        safe_name = html.escape(str(name), quote=True)
        items.append(
            f"<li><span>{safe_name}</span>: "
            f"{count:,} requests</li>"
        )

    return "\n".join(items)

updated = datetime.now(timezone.utc).strftime(
    "%Y-%m-%d %H:%M:%S UTC"
)

content = template_path.read_text(encoding="utf-8")

# Plain-text placeholders are HTML-escaped.
text_values = {
    "UPDATED": updated,
    "TOTAL": f"{total:,}",
    "ERRORS_404": f"{errors_404:,}",
}

for key, value in text_values.items():
    placeholder = "{{" + key + "}}"

    if placeholder not in content:
        raise ValueError(f"Missing placeholder: {placeholder}")

    content = content.replace(
        placeholder,
        html.escape(value, quote=True)
    )

# These fragments are built from escaped log values.
list_values = {
    "TOP_PAGES": top_five(pages),
    "TOP_IPS": top_five(ips),
    "TOP_MISSING": top_five(missing),
}

for key, value in list_values.items():
    placeholder = "{{" + key + "}}"

    if placeholder not in content:
        raise ValueError(f"Missing placeholder: {placeholder}")

    content = content.replace(placeholder, value)

# Atomically publish the generated HTML.
output_path.parent.mkdir(parents=True, exist_ok=True)
temporary_path = None

try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_path.parent,
        prefix=".report-",
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

print(f"Traffic report generated: {output_path}")
PY
