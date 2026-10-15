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
# Resolve the default Release product and report through Xcode, including spaces
sign_args=("$@")
has_app=0
has_report=0
for argument in "$@"; do
    [[ "$argument" != --app && "$argument" != --app=* ]] || has_app=1
    [[ "$argument" != --report && "$argument" != --report=* ]] || has_report=1
done
if (( ! has_app )); then
    sign_args+=(--app "$(python3 "$script_dir/xcode-path.py" Release)")
fi
if (( ! has_report )); then
    sign_args+=(--report "${MAC_SIGN_REPORT:-$(python3 "$script_dir/xcode-path.py" Release --derived-data)/local-signing.json}")
fi
exec python3 "$sign_script" sign --project "$repo_root" "${sign_args[@]}"
