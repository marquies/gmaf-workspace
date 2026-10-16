#!/usr/bin/env bash
# Builds every cloned repo in pom.xml dependency order (see scripts/pom-graph.py).
#
# Maven repos are built with `mvn install` so that downstream repos in this
# workspace can resolve them from the local ~/.m2 repository. When a repo fails,
# everything that depends on it is skipped rather than built against a stale jar.
#
# Usage: build-all.sh [--with-tests] [--dry-run] [extra maven args...]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# common.sh turns on errexit; we handle failures per repo instead of aborting.
set +e

with_tests=0
dry_run=0
maven_args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --with-tests) with_tests=1; shift ;;
        --dry-run)    dry_run=1; shift ;;
        --help|-h)
            sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) maven_args+=("$1"); shift ;;
    esac
done

if [ "${with_tests}" -eq 0 ]; then
    maven_args+=("-DskipTests")
fi

if ! build_plan="$(python3 "${SCRIPT_DIR}/pom-graph.py" --format=machine)"; then
    echo "!! could not derive the build order from the pom.xml files"
    exit 1
fi

if [ -z "${build_plan}" ]; then
    echo "Nothing to build — no repositories cloned yet (run 'mise run clone' first)."
    exit 0
fi

if [ "${dry_run}" -eq 1 ]; then
    python3 "${SCRIPT_DIR}/pom-graph.py" --format=human
    exit 0
fi

built=()
failed=()
skipped=()

contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "${item}" = "${needle}" ] && return 0
    done
    return 1
}

# Returns the name of the first dependency that failed or was skipped, if any.
blocked_by() {
    local deps="$1" dep
    [ -z "${deps}" ] && return 1
    for dep in ${deps//,/ }; do
        if contains "${dep}" ${failed[@]+"${failed[@]}"} ${skipped[@]+"${skipped[@]}"}; then
            echo "${dep}"
            return 0
        fi
    done
    return 1
}

while IFS='|' read -r name kind deps; do
    [ -z "${name}" ] && continue
    dest="${REPOS_DIR}/${name}"

    if blocker="$(blocked_by "${deps}")"; then
        echo "== ${name}: skipped (depends on ${blocker}, which did not build)"
        skipped+=("${name}")
        continue
    fi

    echo "== ${name} (${kind})"
    case "${kind}" in
        maven|python-maven)
            # The settings.xml/toolchains.xml checked into some repos point at
            # GitHub Actions paths, so they are deliberately not passed here.
            if (cd "${dest}" && mvn -ntp ${maven_args[@]+"${maven_args[@]}"} install); then
                built+=("${name}")
            else
                echo "   !! maven build failed in ${name}"
                failed+=("${name}")
            fi
            ;;
        node)
            if [ ! -d "${dest}/node_modules" ]; then
                echo "   node_modules missing, running npm install first"
                if ! (cd "${dest}" && npm install --no-audit --no-fund); then
                    echo "   !! npm install failed in ${name}"
                    failed+=("${name}")
                    continue
                fi
            fi
            if (cd "${dest}" && npm run build --if-present); then
                built+=("${name}")
            else
                echo "   !! npm build failed in ${name}"
                failed+=("${name}")
            fi
            ;;
        cmake)
            if ! command -v nvcc >/dev/null 2>&1; then
                echo "   skipped: no CUDA compiler (nvcc) on this machine — ${name} needs the"
                echo "   CUDA toolkit and a CUDA-capable GPU. Set GMAF_FORCE_CUDA=1 to try anyway."
                if [ "${GMAF_FORCE_CUDA:-0}" != "1" ]; then
                    skipped+=("${name}")
                    continue
                fi
            fi
            if (mkdir -p "${dest}/build" \
                && cd "${dest}/build" \
                && cmake .. -DCMAKE_BUILD_TYPE=Release \
                && cmake --build . --parallel); then
                built+=("${name}")
            else
                echo "   !! cmake build failed in ${name}"
                failed+=("${name}")
            fi
            ;;
        *)
            echo "   (unknown kind '${kind}', no build step defined)"
            skipped+=("${name}")
            ;;
    esac
done <<< "${build_plan}"

echo ""
echo "Build summary"
echo "  built:   ${#built[@]}${built[0]+ — ${built[*]}}"
echo "  skipped: ${#skipped[@]}${skipped[0]+ — ${skipped[*]}}"
echo "  failed:  ${#failed[@]}${failed[0]+ — ${failed[*]}}"

[ "${#failed[@]}" -eq 0 ] || exit 1
