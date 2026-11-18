
#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="${1:-site}"

if [[ ! -d "$SITE_DIR" ]]; then
  echo "ERROR: Site directory not found: $SITE_DIR"
  exit 1
fi

python3 - "$SITE_DIR" <<'PY'
import sys
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

site = Path(sys.argv[1]).resolve()
errors = []

class SiteParser(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.page = page
        self.has_title = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)

        if tag.lower() == "title":
            self.has_title = True

        for attr in ("href", "src"):
            value = attrs.get(attr)
            if not value:
                continue

            if value.startswith(("#", "//", "mailto:", "tel:", "data:")):
                continue

            parsed = urlsplit(value)

            if parsed.scheme or parsed.netloc:
                continue

            path = unquote(parsed.path)

            if not path or path.startswith("/live/"):
                continue

            if path.startswith("/"):
                target = site / path.lstrip("/")
            else:
                target = self.page.parent / path

            target = target.resolve()

            if not target.is_relative_to(site):
                errors.append(f"{self.page}: Link outside site: {value}")
            elif not target.exists():
                errors.append(f"{self.page}: Broken link: {value}")

for file in site.rglob("*"):
    if not file.is_file():
        continue

    if file.stat().st_size > 1024 * 1024:
        errors.append(f"{file}: File exceeds 1 MB")

    if file.suffix.lower() == ".html":
        parser = SiteParser(file)

        try:
            parser.feed(file.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"{file}: Cannot parse HTML: {exc}")
            continue

        if not parser.has_title:
            errors.append(f"{file}: Missing <title>")

if errors:
    for error in errors:
        print(f"ERROR: {error}")
    sys.exit(1)

print("All checks passed")
PY
