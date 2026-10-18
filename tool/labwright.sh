#!/usr/bin/env bash
# Runs a labwright corpus tool against this repository.
#
#   tool/labwright.sh index_corpus            rebuild every index.json whose files are checked out
#   tool/labwright.sh index_corpus --check    report index files that are missing or stale
#   tool/labwright.sh check_corpus            check every metadata file against the tree
#
# Needs git and a Dart SDK. The labwright checkout the tools come from is cloned into
# .labwright (ignored) at LABWRIGHT_REF, develop by default; LABWRIGHT_DIR names an
# existing checkout instead.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tool="${1:?usage: tool/labwright.sh <index_corpus|check_corpus> [args]}"
shift
labwright="${LABWRIGHT_DIR:-$here/.labwright}"
ref="${LABWRIGHT_REF:-develop}"
if [ ! -d "$labwright/.git" ]; then
  git clone -q --depth 1 --branch "$ref" https://github.com/Bud-ro/labwright.git "$labwright"
fi
cd "$labwright"
dart pub get >/dev/null
exec dart run "tool/$tool.dart" "$here" "$@"
