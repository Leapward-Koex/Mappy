#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
binary="$(mktemp /tmp/compass-recorder-test.XXXXXX)"
trap 'rm -f "$binary"' EXIT
cc -std=c99 -Wall -Wextra -Werror -fsanitize=undefined \
  apps/compass-lab/tests/test_recorder.c apps/compass-lab/src/c/recorder.c -o "$binary"
"$binary"
python3 apps/compass-lab/tests/test_export.py
