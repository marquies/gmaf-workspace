#!/usr/bin/env bash
# Shared helpers for the gmaf-workspace scripts.
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# mise.toml sets these; mise.maintainer.toml points them at the private repos.
# The fallbacks keep the scripts working when run outside mise.
REPOS_FILE="${GMAF_MANIFEST:-${WORKSPACE_ROOT}/repos.txt}"
REPOS_DIR="${GMAF_REPOS_DIR:-${WORKSPACE_ROOT}/repos}"
UI_REPO="${GMAF_UI_REPO:-gmaf-mvr-ui-public}"

# Reads repos.txt and emits "name|url|kind|branch|description" lines,
# skipping blank lines and comments.
iter_repos() {
    grep -vE '^\s*(#|$)' "${REPOS_FILE}"
}
