#!/bin/sh
# Run the existing bundle with local API keys; arguments also support CLI checks.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$SCRIPT_DIR/.." "$@" <<'PY'
import os
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
binary = root / "dist/BSDetector.app/Contents/MacOS/BSDetector"
if not binary.is_file() or not os.access(binary, os.X_OK):
    sys.exit("BSDetector bundle is missing. Run ./scripts/build-app.sh first.")

allowed = {"OPENAI_API_KEY", "PARALLEL_API_KEY", "BS_MODEL", "BS_JUDGE_MODEL", "BS_SEARCH_MODE"}
environment = dict(os.environ)
# Prefer repository keys. Read plain assignments only; never execute dotenv text.
env_file = next((path for path in (root / ".env", root / "web/.env") if path.is_file()), None)
if env_file:
    try:
        lines = env_file.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        sys.exit("Could not read the local environment file. Check its permissions and UTF-8 encoding.")
    for line in lines:
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].lstrip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key not in allowed or key in environment:
            continue
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
        environment[key] = value

try:
    os.execve(str(binary), [str(binary), *sys.argv[2:]], environment)
except OSError:
    sys.exit("Could not launch BSDetector. Rebuild the bundle and check its executable permissions.")
PY
