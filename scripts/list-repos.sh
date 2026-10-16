#!/usr/bin/env bash
# Prints the repo manifest as a table, with clone status.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

printf "%-30s %-14s %-9s %s\n" "NAME" "KIND" "CLONED" "DESCRIPTION"
while IFS='|' read -r name url kind branch desc; do
    if [ -d "${REPOS_DIR}/${name}/.git" ]; then
        cloned="yes"
    else
        cloned="no"
    fi
    printf "%-30s %-14s %-9s %s\n" "${name}" "${kind}" "${cloned}" "${desc}"
done < <(iter_repos)
