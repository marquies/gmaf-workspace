#!/usr/bin/env bash
# Builds a code knowledge graph across every cloned repo (maintainer mode only).
#
# Placeholder: no graph tool is wired in yet. Add the tool to [tools] in
# mise.maintainer.toml and replace the loop body with its indexing command.
#
# Usage: graph.sh [tool args...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/common.sh"

while IFS='|' read -r name url kind branch desc; do
    dest="${REPOS_DIR}/${name}"
    if [ ! -d "${dest}/.git" ]; then
        echo "== ${name}: not cloned yet, skipping (run 'mise run clone' first)"
        continue
    fi
    echo "== ${name}: would index ${dest}"
done < <(iter_repos)

echo ""
echo "No knowledge-graph tool configured yet — see scripts/maintainer/graph.sh."
