#!/usr/bin/env bash
# Runs an arbitrary command inside every cloned repo.
# Usage: foreach.sh <command...>
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

if [ "$#" -eq 0 ]; then
    echo "usage: foreach.sh <command...>" >&2
    exit 1
fi

status=0
while IFS='|' read -r name url kind branch desc; do
    dest="${REPOS_DIR}/${name}"
    if [ ! -d "${dest}/.git" ]; then
        echo "== ${name}: not cloned yet, skipping (run 'mise run clone' first)"
        continue
    fi
    echo "== ${name}"
    if ! (cd "${dest}" && "$@"); then
        echo "   !! command failed in ${name}"
        status=1
    fi
done < <(iter_repos)

exit "${status}"
