
#!/usr/bin/env bash
set -euo pipefail

BASE="/var/www/cloudarchitects"
OUTPUT="$BASE/live/status.html"

HOSTNAME=$(hostname)
TIME=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
UPTIME=$(uptime -p)
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
MEMORY=$(free -h | awk '/^Mem:/ {print $3 " / " $2}')
DISK=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')
DISK_PERCENT=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')

if systemctl is-active --quiet nginx; then
  NGINX="RUNNING"
else
  NGINX="DOWN - WARNING"
fi

RELEASE=$(basename "$(readlink -f "$BASE/current")")
RECENT=$(tail -n 5 "$BASE/deploys.log" 2>/dev/null || true)

if (( DISK_PERCENT >= 90 )); then
  DISK_WARNING="WARNING: Disk usage is high!"
else
  DISK_WARNING="OK"
fi

cat > "$OUTPUT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="60">
  <title>Cloude Architects - Server Status</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 30px; }
    pre { background: #f4f4f4; padding: 15px; overflow-x: auto; }
    .warning { color: red; font-weight: bold; }
  </style>
</head>
<body>
  <h1>Cloude Architects - Live Server Status</h1>
  <p><strong>Hostname:</strong> $HOSTNAME</p>
  <p><strong>Updated:</strong> $TIME</p>
  <p><strong>Uptime:</strong> $UPTIME</p>
  <p><strong>Load Average:</strong> $LOAD</p>
  <p><strong>Memory:</strong> $MEMORY</p>
  <p><strong>Disk:</strong> $DISK</p>
  <p class="warning">$DISK_WARNING</p>
  <p><strong>Nginx:</strong> $NGINX</p>
  <p><strong>Active Release:</strong> $RELEASE</p>
  <h2>Last Five Deployments / Rollbacks</h2>
  <pre>$RECENT</pre>
</body>
</html>
EOF

echo "Status page generated: $OUTPUT"
