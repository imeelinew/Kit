#!/bin/zsh
set -euo pipefail

# Use the installed mac-sign skill without embedding a user-specific plugin path.
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
sign_script="${MAC_SIGN_SCRIPT:-}"
if [[ -z "$sign_script" ]]; then
    sign_script=$(python3 - <<'PYCODE'
import os
from pathlib import Path
root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
paths = list((root / "plugins/cache").glob("*/ai-mac-sign/*/skills/mac-sign/scripts/mac_sign.py"))
def version(path):
    return tuple(int(part) for part in path.parents[3].name.split(".") if part.isdigit())
if not paths:
    raise SystemExit("Install the ai-mac-sign plugin or set MAC_SIGN_SCRIPT to its mac_sign.py")
print(max(paths, key=version))
PYCODE
    )
fi
[[ -f "$sign_script" ]] || {
    print -u2 "Signing skill not found: $sign_script"
    exit 69
}
exec python3 "$sign_script" sign --project "$repo_root" "$@"
