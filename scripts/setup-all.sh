#!/usr/bin/env bash
# Bootstraps each cloned repo for local development, per its project kind.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

status=0
while IFS='|' read -r name url kind branch desc; do
    dest="${REPOS_DIR}/${name}"
    if [ ! -d "${dest}/.git" ]; then
        echo "== ${name}: not cloned yet, skipping (run 'mise run clone' first)"
        continue
    fi
    echo "== ${name} (${kind})"
    case "${kind}" in
        maven)
            (cd "${dest}" && mvn -q -ntp -DskipTests dependency:go-offline) \
                || { echo "   !! maven dependency resolution failed in ${name}"; status=1; }
            ;;
        node)
            # `npm ci` honours the lockfile without rewriting it; plain
            # `npm install` leaves package-lock.json modified in the checkout.
            if [ -f "${dest}/package-lock.json" ]; then
                (cd "${dest}" && npm ci --no-audit --no-fund) \
                    || { echo "   !! npm ci failed in ${name}"; status=1; }
            else
                (cd "${dest}" && npm install --no-audit --no-fund) \
                    || { echo "   !! npm install failed in ${name}"; status=1; }
            fi
            ;;
        python-maven)
            (cd "${dest}" && mvn -q -ntp -DskipTests dependency:go-offline) \
                || { echo "   !! maven dependency resolution failed in ${name}"; status=1; }
            if [ -f "${dest}/requirements.txt" ]; then
                (cd "${dest}" && python3 -m venv .venv \
                    && .venv/bin/pip install -q -r requirements.txt) \
                    || { echo "   !! python venv setup failed in ${name}"; status=1; }
            else
                echo "   (no requirements.txt found; set up the Python/YOLO side manually, see its README)"
            fi
            ;;
        cmake)
            if command -v cmake >/dev/null 2>&1; then
                (mkdir -p "${dest}/build" && cd "${dest}/build" && cmake .. -DCMAKE_BUILD_TYPE=Release) \
                    || { echo "   !! cmake configure failed in ${name} (needs CUDA toolkit + a CUDA-capable GPU/driver on this machine)"; status=1; }
            else
                echo "   !! cmake not found; install cmake + the CUDA toolkit manually for ${name}"
                status=1
            fi
            ;;
        *)
            echo "   (unknown kind '${kind}', no automatic setup step)"
            ;;
    esac
done < <(iter_repos)

echo ""
if [ "${status}" -eq 0 ]; then
    echo "All repos bootstrapped successfully."
else
    echo "Some repos failed to bootstrap — see '!!' lines above."
fi
exit "${status}"
