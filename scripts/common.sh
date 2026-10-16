#!/usr/bin/env bash
# Shared helpers for the gmaf-workspace scripts.
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_FILE="${WORKSPACE_ROOT}/repos.txt"
REPOS_DIR="${WORKSPACE_ROOT}/repos"

# Reads repos.txt and emits "name|url|kind|branch|description" lines,
# skipping blank lines and comments.
iter_repos() {
    grep -vE '^\s*(#|$)' "${REPOS_FILE}"
}
