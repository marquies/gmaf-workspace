#!/usr/bin/env bash
# Deletes the checkouts under ./repos so the workspace can be cloned fresh.
#
# Refuses to touch a repo that holds work you would not get back — uncommitted
# changes to tracked files, untracked files that are not build output, commits
# that exist on no remote, or stashed entries. Override with --force.
#
# Usage: clean-all.sh [--dry-run] [--force] [--artifacts]
#   --dry-run    list what would be removed, delete nothing
#   --force      delete even when a repo holds unsaved work
#   --artifacts  keep the checkouts, delete only build output
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# common.sh turns on errexit; this script reports per repo instead of aborting.
set +e

# Paths that are build output rather than work worth keeping. Some of the GMAF
# repos commit their build output (GMAF tracks target/classes/*.class), so this
# has to apply to modified tracked files too, not just untracked ones.
IGNORABLE_PATHS='^(target/|build/|node_modules/|\.venv/|\.omc/|\.DS_Store)'

dry_run=0
force=0
artifacts_only=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)   dry_run=1; shift ;;
        --force)     force=1; shift ;;
        --artifacts) artifacts_only=1; shift ;;
        --help|-h)
            sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown option: $1 (try --help)"; exit 2 ;;
    esac
done

if [ ! -d "${REPOS_DIR}" ]; then
    echo "Nothing to clean — ${REPOS_DIR} does not exist."
    exit 0
fi

# Echoes a reason when the repo holds work that deleting it would destroy.
unsaved_work() {
    local dir="$1"
    [ -d "${dir}/.git" ] || return 1

    local modified
    modified="$(git -C "${dir}" status --porcelain --untracked-files=no 2>/dev/null \
        | cut -c4- | grep -vE "${IGNORABLE_PATHS}" | head -3 | tr '\n' ' ')"
    if [ -n "${modified}" ]; then
        echo "uncommitted changes (${modified% })"
        return 0
    fi
    local untracked
    untracked="$(git -C "${dir}" ls-files --others --exclude-standard 2>/dev/null \
        | grep -vE "${IGNORABLE_PATHS}" | head -3 | tr '\n' ' ')"
    if [ -n "${untracked}" ]; then
        echo "untracked files (${untracked% })"
        return 0
    fi
    local unpushed
    unpushed="$(git -C "${dir}" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${unpushed}" != "0" ]; then
        echo "${unpushed} commit(s) on no remote"
        return 0
    fi
    local stashes
    stashes="$(git -C "${dir}" stash list 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${stashes}" != "0" ]; then
        echo "${stashes} stash entr(y/ies)"
        return 0
    fi
    return 1
}

removable=()
blocked=()
blocked_reasons=()

while IFS='|' read -r name url kind branch desc; do
    dest="${REPOS_DIR}/${name}"
    [ -e "${dest}" ] || continue
    if reason="$(unsaved_work "${dest}")" && [ "${force}" -eq 0 ]; then
        blocked+=("${name}")
        blocked_reasons+=("${reason}")
    else
        removable+=("${name}")
    fi
done < <(iter_repos)

# Directories in ./repos that the manifest no longer lists are always stale.
orphans=()
for dir in "${REPOS_DIR}"/*/; do
    [ -d "${dir}" ] || continue
    name="$(basename "${dir}")"
    if ! iter_repos | cut -d'|' -f1 | grep -qx "${name}"; then
        orphans+=("${name}")
    fi
done

if [ "${artifacts_only}" -eq 1 ]; then
    echo "Removing build output only, keeping the checkouts:"
    found=0
    while IFS= read -r path; do
        [ -z "${path}" ] && continue
        found=1
        # GMAF commits target/classes/*.class, so deleting it would show up as a
        # pile of deleted tracked files rather than as a clean slate.
        repo_dir="$(dirname "${path}")"
        if [ -n "$(git -C "${repo_dir}" ls-files -- "$(basename "${path}")" 2>/dev/null | head -1)" ]; then
            echo "  ${path#"${WORKSPACE_ROOT}"/} (tracked in git, left alone)"
            continue
        fi
        echo "  ${path#"${WORKSPACE_ROOT}"/}"
        [ "${dry_run}" -eq 0 ] && rm -rf "${path}"
    done < <(find "${REPOS_DIR}" -mindepth 2 -maxdepth 2 \
        \( -name target -o -name build -o -name node_modules -o -name .venv \) -type d 2>/dev/null)
    [ "${found}" -eq 0 ] && echo "  (none found)"
    [ "${dry_run}" -eq 1 ] && echo "" && echo "Dry run — nothing was deleted."
    exit 0
fi

if [ "${#blocked[@]}" -gt 0 ]; then
    echo "Refusing to delete — these hold work that is not saved anywhere else:"
    index=0
    while [ "${index}" -lt "${#blocked[@]}" ]; do
        echo "  ${blocked[${index}]}: ${blocked_reasons[${index}]}"
        index=$((index + 1))
    done
    echo ""
    echo "Commit, push or stash them, or re-run with --force to delete anyway."
fi

total=$(( ${#removable[@]} + ${#orphans[@]} ))
if [ "${total}" -eq 0 ]; then
    [ "${#blocked[@]}" -eq 0 ] && echo "Nothing to clean — no checkouts present."
    [ "${#blocked[@]}" -gt 0 ] && exit 1
    exit 0
fi

echo "Deleting ${total} checkout(s) from ${REPOS_DIR#"${WORKSPACE_ROOT}"/}/:"
for name in ${removable[@]+"${removable[@]}"}; do
    echo "  ${name}"
    [ "${dry_run}" -eq 0 ] && rm -rf "${REPOS_DIR:?}/${name}"
done
for name in ${orphans[@]+"${orphans[@]}"}; do
    echo "  ${name} (not in repos.txt any more)"
    [ "${dry_run}" -eq 0 ] && rm -rf "${REPOS_DIR:?}/${name}"
done

echo ""
if [ "${dry_run}" -eq 1 ]; then
    echo "Dry run — nothing was deleted."
else
    echo "Done. Run 'mise run clone' (or 'mise run reset') to check them out again."
fi

[ "${#blocked[@]}" -eq 0 ] || exit 1
exit 0
