
#!/usr/bin/env bash
set -euo pipefail

BASE="/var/www/cloudarchitects"
LOG="/var/log/nginx/cloudarchitects-access.log"
OUTPUT="$BASE/live/report.html"

[[ -r "$LOG" ]] || {
  echo "ERROR: Cannot read Nginx access log"
  exit 1
}

python3 - "$LOG" "$OUTPUT" <<'PY'
import sys
import re
import html
from pathlib import Path
from collections import Counter
from datetime import datetime, timezone

log_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

total = 0
errors_404 = 0
pages = Counter()
ips = Counter()
missing = Counter()

pattern = re.compile(
    r'^(\S+) .*?"[A-Z]+ (\S+) [^"]+" (\d{3}) '
)

with log_path.open(errors="replace") as log:
    for line in log:
        match = pattern.search(line)
        if not match:
            continue

        ip, path, status = match.groups()

        # Ignore monitoring page requests.
        if path.split("?")[0].startswith("/live/"):
            continue

        total += 1
        pages[path] += 1
        ips[ip] += 1

        if status == "404":
            errors_404 += 1
            missing[path] += 1

def top_five(counter):
    if not counter:
        return "<li>No data yet</li>"

    return "\n".join(
        f"<li>{html.escape(name)}: {count}</li>"
        for name, count in counter.most_common(5)
    )

updated = datetime.now(timezone.utc).strftime(
    "%Y-%m-%d %H:%M:%S UTC"
)

content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="300">
  <title>Cloude Architects - Traffic Report</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 30px; }}
    li {{ margin: 8px 0; }}
  </style>
</head>
<body>
  <h1>Cloude Architects - Traffic Report</h1>
  <p><strong>Updated:</strong> {updated}</p>
  <p><strong>Total Requests:</strong> {total}</p>
  <p><strong>404 Errors:</strong> {errors_404}</p>

  <h2>Top 5 Requested Pages</h2>
  <ol>{top_five(pages)}</ol>

  <h2>Top 5 Visitor IPs</h2>
  <ol>{top_five(ips)}</ol>

  <h2>Top 5 Missing Pages (404)</h2>
  <ol>{top_five(missing)}</ol>
</body>
</html>
"""

output_path.write_text(content, encoding="utf-8")
print(f"Traffic report generated: {output_path}")
PY
