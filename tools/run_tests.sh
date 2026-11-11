#!/bin/zsh
# Runs the unit tests at low priority with one job, so the Mac stays responsive.
set -euo pipefail
cd "$(dirname "$0")/.."
exec nice -n 19 swift test -j 1 "$@"
