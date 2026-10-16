#!/usr/bin/env bash
# Runs the GMAF dev environment: the GMAF-UI desktop client (which also hosts the
# REST/SOAP API the web client talks to) and the React web UI prototype.
#
# Both run in the foreground with their output interleaved and tagged. Ctrl-C
# stops both.
#
# GMAF-UI resolves conf/gmaf.config and every data folder in it relative to its
# working directory, so --basedir picks which conf folder and data set it uses.
# (de.swa.ui.Main takes a basedir argument, but the field is never read — the
# working directory is the only thing that actually decides this.)
#
# Usage: dev.sh [--basedir=<dir>] [--ui-only] [--web-only]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
set +e
# Give each background job its own process group so Ctrl-C can take down the
# whole tree — npm start spawns react-scripts, which spawns further children.
set -m

UI_DIR="${REPOS_DIR}/gmaf-mvr-ui-public"
WEB_DIR="${REPOS_DIR}/gmaf-mvr-webui-prototype"

# Where GMAF-UI runs, i.e. which conf/ and data folders it picks up. A bare name
# is taken as a repo under ./repos; anything else is used as a path.
BASEDIR_ARG="${GMAF_BASEDIR:-gmaf-mvr}"

# Defaults come from de.swa.ui.Configuration; conf/gmaf.config overrides them.
REST_PORT="${GMAF_REST_PORT:-8242}"
SOAP_PORT="${GMAF_SOAP_PORT:-8481}"
WEB_PORT="${PORT:-3000}"

run_ui=1
run_web=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ui-only)  run_web=0; shift ;;
        --web-only) run_ui=0; shift ;;
        --basedir)  BASEDIR_ARG="${2:-}"; shift 2 ;;
        --basedir=*) BASEDIR_ARG="${1#--basedir=}"; shift ;;
        --help|-h)
            sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown option: $1 (try --help)"; exit 2 ;;
    esac
done

port_owner() {
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -1
}

fail() { echo "!! $*" >&2; exit 1; }

# ---- preflight ------------------------------------------------------------

# Reads a key from gmaf.config: "key = value", ignoring comments.
config_value() {
    grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null \
        | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

UI_JAR=""
BASEDIR=""
if [ "${run_ui}" -eq 1 ]; then
    [ -d "${UI_DIR}" ] || fail "gmaf-mvr-ui-public is not cloned — run 'mise run clone'"

    case "${BASEDIR_ARG}" in
        */*|.|..) BASEDIR="${BASEDIR_ARG}" ;;
        *)        BASEDIR="${REPOS_DIR}/${BASEDIR_ARG}" ;;   # bare name -> ./repos/<name>
    esac
    [ -d "${BASEDIR}" ] || fail "basedir '${BASEDIR_ARG}' does not exist (looked in ${BASEDIR})"
    BASEDIR="$(cd "${BASEDIR}" && pwd)"
    [ -f "${BASEDIR}/conf/gmaf.config" ] \
        || fail "no conf/gmaf.config in ${BASEDIR} — pass --basedir=<dir> pointing at one that has it"

    # Every folder named in gmaf.config resolves relative to the working
    # directory. Configuration.check() mkdirs the output ones (graphcodes,
    # mmfgs, rdf, thumbnails, export, flows, temp) on startup, but NOT
    # collectionPath — a wrong value there just logs "path X does not exist"
    # and leaves you with an empty collection, which is easy to misread as the
    # config being ignored altogether.
    missing=""
    collection_paths="$(config_value "${BASEDIR}/conf/gmaf.config" collectionPath)"
    old_ifs="${IFS}"; IFS=','
    for value in ${collection_paths}; do
        IFS="${old_ifs}"
        value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "${value}" ] || continue
        case "${value}" in /*) target="${value}" ;; *) target="${BASEDIR}/${value}" ;; esac
        [ -d "${target}" ] || missing="${missing}  collectionPath = ${value}
"
        IFS=','
    done
    IFS="${old_ifs}"
    # The shade plugin attaches the runnable fat jar with an -executable
    # classifier; the plain GMAF-UI.jar has no Main-Class and no dependencies.
    UI_JAR="$(ls -t "${UI_DIR}"/target/*-executable.jar 2>/dev/null | head -1)"
    [ -n "${UI_JAR}" ] || fail "no runnable jar in gmaf-mvr-ui-public/target — run 'mise run build' first"
    for port in "${REST_PORT}" "${SOAP_PORT}"; do
        owner="$(port_owner "${port}")"
        [ -n "${owner}" ] && fail "port ${port} is already in use (pid ${owner}) — stop that process first"
    done
fi

if [ "${run_web}" -eq 1 ]; then
    [ -d "${WEB_DIR}" ] || fail "gmaf-mvr-webui-prototype is not cloned — run 'mise run clone'"
    owner="$(port_owner "${WEB_PORT}")"
    [ -n "${owner}" ] && fail "port ${WEB_PORT} is already in use (pid ${owner}) — stop it or set PORT=<other>"
    if [ ! -d "${WEB_DIR}/node_modules" ]; then
        echo "== installing web UI dependencies (node_modules missing)"
        if [ -f "${WEB_DIR}/package-lock.json" ]; then
            (cd "${WEB_DIR}" && npm ci --no-audit --no-fund) || fail "npm ci failed"
        else
            (cd "${WEB_DIR}" && npm install --no-audit --no-fund) || fail "npm install failed"
        fi
    fi
fi

# ---- run ------------------------------------------------------------------

# awk rather than `sed -u`/`sed -l`, which spell line buffering differently on
# BSD and GNU.
prefix() { awk -v tag="$1" '{ print tag $0; fflush() }'; }

UI_PID=""
WEB_PID=""
shutting_down=0

cleanup() {
    [ "${shutting_down}" -eq 1 ] && return
    shutting_down=1
    trap - INT TERM EXIT
    # Off before killing, so the shell does not print "Terminated: 15" notices
    # for jobs we are deliberately stopping.
    set +m
    echo ""
    echo "== shutting down"
    # The shell announces "Terminated: 15" on stderr as it reaps each job it is
    # being asked to stop; `set +m` does not suppress that, redirecting does.
    exec 2>/dev/null
    for pid in "${UI_PID}" "${WEB_PID}"; do
        [ -n "${pid}" ] || continue
        kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null
    done
    sleep 1
    for pid in "${UI_PID}" "${WEB_PID}"; do
        [ -n "${pid}" ] || continue
        kill -KILL "-${pid}" 2>/dev/null
    done
    wait 2>/dev/null
}

# Exit 0, not the conventional 130: Ctrl-C is how a dev session normally ends,
# and mise would otherwise report "ERROR task failed" every single time.
on_signal() { cleanup; exit 0; }
trap on_signal INT TERM
trap cleanup EXIT

if [ "${run_ui}" -eq 1 ]; then
    echo "== GMAF-UI      $(basename "${UI_JAR}")"
    echo "   basedir      ${BASEDIR#"${WORKSPACE_ROOT}"/}  (conf/gmaf.config + data folders)"
    if [ -n "${missing}" ]; then
        echo "   !! collection folder named in conf/gmaf.config does not exist:"
        printf '%s' "${missing}" | sed 's/^/   /'
        echo "      GMAF logs 'path ... does not exist' and starts with an empty"
        echo "      collection — point collectionPath at a folder that has assets."
    fi
    echo "   REST API     http://localhost:${REST_PORT}/gmaf/gmafApi"
    echo "   Swagger UI   http://localhost:${REST_PORT}/swagger-ui/index.html"
    echo "   SOAP API     http://localhost:${SOAP_PORT}/gmaf/gmafApi"
    # The jar comes from the ui-public build, but the process runs in BASEDIR —
    # that, and only that, decides which conf/gmaf.config and data it uses.
    ( cd "${BASEDIR}" && exec java -jar "${UI_JAR}" ) > >(prefix "[gmaf-ui] ") 2>&1 &
    UI_PID=$!
fi

if [ "${run_web}" -eq 1 ]; then
    echo "== Web UI       http://localhost:${WEB_PORT}  (expects the REST API on ${REST_PORT})"
    # BROWSER=none keeps react-scripts from hijacking a browser window; CI=false
    # stops it treating lint warnings as build failures.
    ( cd "${WEB_DIR}" && exec env BROWSER=none CI=false PORT="${WEB_PORT}" npm start ) \
        > >(prefix "[webui]   ") 2>&1 &
    WEB_PID=$!
fi

echo ""
echo "Ctrl-C stops everything."
echo ""

# `wait -n` is bash 4+; macOS ships bash 3.2, so poll instead. If one side dies
# on its own the EXIT trap takes the other down with it.
while :; do
    if [ -n "${UI_PID}" ] && ! kill -0 "${UI_PID}" 2>/dev/null; then
        echo "!! GMAF-UI exited on its own — stopping the web UI too"
        exit 1
    fi
    if [ -n "${WEB_PID}" ] && ! kill -0 "${WEB_PID}" 2>/dev/null; then
        echo "!! web UI exited on its own — stopping GMAF-UI too"
        exit 1
    fi
    sleep 1
done
