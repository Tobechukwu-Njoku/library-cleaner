#!/bin/bash
# Run the test suite in a container, since the scripts need bash 4.1+
# and GNU findutils/coreutils, which macOS does not have.
#
#   ./tests/docker-run.sh
#
# Uses debian:bookworm-slim rather than the Alpine bash image: Unraid
# ships GNU tools, and BusyBox differs on `find -printf` and `stat -c`.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm -i \
    -v "$REPO:/repo:ro" \
    debian:bookworm-slim \
    bash -s /repo < "$REPO/tests/run_tests.sh"
