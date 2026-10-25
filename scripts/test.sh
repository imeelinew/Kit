#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-all-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
export KIT_TEST_BUILD_DIR=${KIT_TEST_BUILD_DIR:-"$test_dir/build"}
export NSUnbufferedIO=YES

run_bounded() {
    python3 - "$@" <<'PYCODE'
import os
import signal
import subprocess
import sys

process = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    status = process.wait(timeout=int(os.environ.get("KIT_TEST_RUNNER_TIMEOUT", "600")))
    sys.exit(status if status >= 0 else 128 - status)
except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    print("FAIL: runner timeout" if isinstance(error, subprocess.TimeoutExpired) else "Interrupted", flush=True)
    sys.exit(124 if isinstance(error, subprocess.TimeoutExpired) else 130)
PYCODE
}

if (( $# > 0 )); then
    run_bounded "$repo_root/scripts/test-app.sh" "$@"
    exit $?
fi

failed=0
for suite in app capture clipboard-search clipboard-deduplication clipboard-retention clipboard-ocr clipboard-list; do
    print "RUN: $suite"
    if run_bounded "$repo_root/scripts/test-$suite.sh"; then
        print "PASS: $suite runner"
    else
        print "FAIL: $suite runner"
        (( failed += 1 ))
    fi
done
print "7 runners, $failed failures"
(( failed == 0 ))
