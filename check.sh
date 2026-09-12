#!/bin/bash
# Runs the decision pipeline against your live rules. No app launch needed.
#   ./check.sh                       the whole suite
#   ./check.sh "Some Video Title"    judge one title, with the numbers
#   ./check.sh --margin 0.03         try a threshold without saving it
#   ./check.sh --learn "taught" "probe"   see how far a lesson spreads
set -euo pipefail
cd "$(dirname "$0")"

OUT=.build/rulecheck
# The pure-logic half of the app. Anything the checker needs must be listed here,
# or the build breaks in a way that looks like a test failure.
SRC=(Tools/RuleCheck/main.swift
     Sources/Ward/Rules.swift
     Sources/Ward/Semantic.swift
     Sources/Ward/Judge.swift
     Sources/Ward/History.swift
     Sources/Ward/Challenge.swift
     Sources/Ward/Store.swift)

mkdir -p .build
if [[ ! -x "$OUT" ]] || [[ -n "$(find "${SRC[@]}" -newer "$OUT" 2>/dev/null)" ]]; then
    if ! swiftc -O -o "$OUT" "${SRC[@]}"; then
        echo "check.sh: the checker itself failed to build (see errors above)" >&2
        exit 2
    fi
fi
exec "$OUT" "$@"
