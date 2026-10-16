#!/usr/bin/env bash
# Clones every repo listed in repos.txt into ./repos/<name> (skips existing checkouts).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

mkdir -p "${REPOS_DIR}"

while IFS='|' read -r name url kind branch desc; do
    dest="${REPOS_DIR}/${name}"
    if [ -d "${dest}/.git" ]; then
        echo "== ${name}: already cloned, skipping (run 'mise run pull' to update)"
        continue
    fi
    echo "== ${name}: cloning ${url} (${kind})"
    git clone --origin origin --branch "${branch}" "${url}" "${dest}"
done < <(iter_repos)

echo ""
echo "Done. Repos are under: ${REPOS_DIR}"
