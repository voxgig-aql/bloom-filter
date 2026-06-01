#!/usr/bin/env bash
#
# Activate the CI workflow.
#
# GitHub only runs workflows from .github/workflows/, but this module's
# workflow ships parked in ci/test.yml because the automation token that
# created the branch lacked the GitHub `workflow` OAuth scope and could
# not write under .github/workflows/.
#
# Run this from a checkout with a credential that HAS `workflow` scope to
# move the workflow into its live location, drop the staging files, and
# commit. The workflow itself needs no edits.
#
# Usage:
#   ci/activate.sh           # move, commit (does not push)
#   ci/activate.sh --push    # also push the current branch
set -euo pipefail

# Resolve the repo root from this script's location so it works from any cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

src="ci/test.yml"
dest=".github/workflows/test.yml"

if [[ ! -f "$src" ]]; then
  if [[ -f "$dest" ]]; then
    echo "Already activated: $dest exists and $src is gone. Nothing to do."
    exit 0
  fi
  echo "error: $src not found and $dest missing — nothing to activate." >&2
  exit 1
fi

echo "Moving $src -> $dest"
mkdir -p .github/workflows
git mv "$src" "$dest"

# The staging README only documented this workaround; it is obsolete once
# the workflow is live.
if [[ -f ci/README.md ]]; then
  git rm ci/README.md
fi

# Drop the ci/ directory if nothing else remains in it.
rmdir ci 2>/dev/null || true

git commit -m "Activate CI workflow"

if [[ "${1:-}" == "--push" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  echo "Pushing $branch"
  git push -u origin "$branch"
fi

echo "Done. Workflow is now at $dest"
