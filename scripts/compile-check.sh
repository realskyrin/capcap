#!/bin/bash
#
# Quick compile-check for capcap.
#
# Looks at Swift files changed since HEAD (including untracked new files),
# runs `swift build -c debug`, and surfaces only compilation errors.
#
# Exits 0 when the current tree compiles cleanly (or has nothing to check),
# and 1 when the compiler or linker reports errors.
#
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Modified tracked files (excluding deletions) + untracked files, deduped.
changed_files=$( { \
    git diff --name-only --diff-filter=d HEAD; \
    git ls-files --others --exclude-standard; \
  } | sort -u)

if [ -z "$changed_files" ]; then
  echo "No modified files found — nothing to check."
  exit 0
fi

# Filter to files that actually affect the Swift build.
relevant=()
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.swift|Package.swift|Package.resolved)
      relevant+=("$file")
      ;;
  esac
done <<< "$changed_files"

if [ ${#relevant[@]} -eq 0 ]; then
  echo "No Swift sources changed — skipping compile check."
  exit 0
fi

echo "Changed Swift sources:"
printf '  %s\n' "${relevant[@]}"
echo ""
echo "Running: swift build -c debug"
echo ""

# Run swift build and capture combined output. SwiftPM emits compiler
# diagnostics in the form "<path>:<line>:<col>: error: <message>" and linker
# diagnostics prefixed with "ld:" / "Undefined symbols".
set +e
build_output=$(swift build -c debug 2>&1)
exit_code=$?
set -e

# Extract error lines only (compiler + linker). Match:
#   /abs/path/File.swift:12:5: error: ...
#   error: ...
#   ld: ...
#   Undefined symbols ...
errors=$(printf '%s\n' "$build_output" \
  | grep -E '(: error: |^error: |^ld: |Undefined symbols)' \
  || true)

if [ -n "$errors" ]; then
  echo "✗ Compilation errors found:"
  echo ""
  echo "$errors"
  exit 1
elif [ $exit_code -ne 0 ]; then
  echo "✗ Build failed with non-compilation error:"
  echo ""
  echo "$build_output"
  exit 1
else
  echo "✓ No compilation errors found"
  exit 0
fi
