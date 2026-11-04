#!/usr/bin/env bash
set -euo pipefail

# Seats and the Codex launcher with PATH unset, on a fresh full target.
# /bin/bash is 3.2 on macOS and 5 on Linux, so CI runs this on both.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
campaign="$(mktemp -d)"
trap 'rm -rf "$campaign"' EXIT
mkdir -p "$campaign/target"
bash "$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh" --target "$campaign/target" --workflow full
python3 - "$ROOT_DIR" "$campaign" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

root, campaign = map(Path, sys.argv[1:])
env = dict(os.environ, SEATS_QA_BASH="/bin/bash")
env.pop("PATH", None)
subprocess.run([sys.executable, str(root / "scripts/test-agent-seats.py"),
                str(campaign / "target"), str(root / "agent-bootstrap/agent-seats.sh"),
                str(campaign / "seats.json")], env=env, check=True)
subprocess.run([sys.executable, str(root / "scripts/test-agent-seats-launcher.py")],
               env=env, check=True)
PY
