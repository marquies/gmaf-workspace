# gmaf-workspace

A [mise](https://mise.jdx.dev/)-driven workspace that manages local checkouts of all the
**GMAF** (Generic Multimedia Analysis Framework) repositories, so you can clone, pin the
right toolchains, and bootstrap every sub-project with one command instead of doing it
project by project.

This repo does not vendor the GMAF projects themselves (`repos/` is git-ignored). It is a
thin orchestration layer: a manifest (`repos.txt`) plus `mise` tasks that clone, update,
and bootstrap each project into `./repos/<name>`.

## Prerequisites

- [mise](https://mise.jdx.dev/getting-started.html) installed (`curl https://mise.run | sh`)
- git

## Quick start

```sh
mise trust        # first time only, approves this repo's mise.toml
mise install      # installs the pinned Java/Maven/Node/Python versions
mise run clone    # clones every repo in repos.txt into ./repos
mise run setup    # resolves Maven deps / npm installs for each repo
mise run build    # builds every repo in pom.xml dependency order
mise run dev      # runs GMAF-UI + the web UI prototype
mise run status   # git status across every checked-out repo
mise run list     # show the manifest with clone status
```

Every `mise run <task>` activates the pinned toolchain versions automatically (no manual
`SDKMAN`/`nvm`/`pyenv` juggling needed) because `mise.toml` pins:

| tool   | version |
|--------|---------|
| java   | 21      |
| maven  | latest  |
| node   | lts     |
| python | 3.11    |

(Python is used by `scripts/pom-graph.py`, which derives the build order.)

## Repositories managed here

| repo | kind | purpose |
|------|------|---------|
| [GMAF](https://github.com/marquies/GMAF) | maven | Core framework: the Multimedia Feature Vector Graph (MMFG) model |
| [gmaf-mvr](https://github.com/marquies/gmaf-mvr) | maven | GMAF-MVR core (Metaverse Video Recording pipeline) |
| [gmaf-mvr-api](https://github.com/marquies/gmaf-mvr-api) | maven | GMAF-MVR REST API |
| [gmaf-mvr-semantics-public](https://github.com/marquies/gmaf-mvr-semantics-public) | maven | GMAF-MVR semantics/explainability module |
| [gmaf-mvr-service-public](https://github.com/marquies/gmaf-mvr-service-public) | maven | GMAF-MVR service layer |
| [gmaf-mvr-ui-public](https://github.com/marquies/gmaf-mvr-ui-public) | maven | GMAF-MVR UI backend |
| [gmaf-mvr-webui-prototype](https://github.com/marquies/gmaf-mvr-webui-prototype) | node | GMAF-MVR React web UI prototype |

The authoritative list lives in [`repos.txt`](./repos.txt) — one line per repo:
`name|git_url|kind|default_branch|description`. Add a new GMAF repo by appending a line
there; no script changes are needed for the common kinds (`maven`, `node`, `cmake`,
`python-maven`).

## Building

```sh
mise run build-order                # print the derived build order, build nothing
mise run build                      # build everything, dependencies first
mise run build -- --with-tests      # same, but don't skip tests
mise run build -- -o                # pass extra args straight to maven (here: offline)
```

The build order is **derived from the POMs, not hardcoded**: `scripts/pom-graph.py`
reads the `pom.xml` of every cloned Maven repo, records which `groupId:artifactId:version`
each one produces, matches that against the dependencies the others declare, and
topologically sorts the result. Add a repo to `repos.txt` and the order updates itself.

Maven repos are built with `mvn install` (not `package`) so downstream repos in the
workspace can resolve them from the local `~/.m2`. If a repo fails, everything that
depends on it is **skipped** rather than built against a stale jar, so the summary
distinguishes a real failure from its fallout. Independent repos still build.

The current graph:

```
gmaf-mvr ─┬─> gmaf-mvr-api ──> gmaf-mvr-service-public ─┐
          │                                             ├─> gmaf-mvr-ui-public
          └─> gmaf-mvr-semantics-public ────────────────┘

GMAF (independent)                 gmaf-mvr-webui-prototype (node, independent)
```

Worth knowing: `GMAF` is an isolated node. None of the other repos currently in the
manifest declare a dependency on `de.swa:gmaf`, so it builds first but nothing consumes
it — the GMAF-MVR line depends on `de.swa:gmaf-mvr` instead.

### Known upstream POM fixes

`gmaf-mvr-service-public` declared `com.fasterxml.jackson.core:jackson-databind` twice
with conflicting versions (a hardcoded `2.18.2` plus `${jackson.version}` = `2.17.1`),
which Maven rejected outright with *dependencies.dependency.(groupId:artifactId:type:
classifier) must be unique*. Fixed by dropping the hardcoded declaration and raising
`<jackson.version>` to `2.18.2`, so `jackson-databind`, `jackson-core`, and
`jackson-annotations` all move in lockstep off the one property.

Fixed upstream in [gmaf-mvr-service-public#1](https://github.com/marquies/gmaf-mvr-service-public/pull/1),
so a fresh `mise run clone` picks it up — nothing needs patching by hand any more.

The `settings.xml`/`toolchains.xml` files checked into a few repos point at GitHub Actions
paths (`/opt/hostedtoolcache/...`), so the build deliberately does **not** pass them to
Maven.

## Day-to-day commands

```sh
mise run pull                       # git pull --ff-only everywhere
mise run status                     # git status -sb everywhere
mise run exec -- git log -1 --oneline   # run any command in every cloned repo
```

## Running the dev environment

```sh
mise run dev                              # GMAF-UI + the React web UI prototype
mise run dev -- --ui-only                 # just GMAF-UI (and with it the REST/SOAP API)
mise run dev -- --web-only                # just the React dev server
mise run dev -- --basedir=gmaf-mvr-ui-public   # run against a different conf/ + data set
GMAF_BASEDIR=/some/where mise run dev     # same, via environment
PORT=3001 mise run dev                    # move the web dev server off port 3000
```

Both processes run in the foreground with their output interleaved and tagged
(`[gmaf-ui]` / `[webui]`). Ctrl-C stops both, including the children `npm start`
spawns. If either side exits on its own, the other is shut down too.

| what | where | notes |
|------|-------|-------|
| GMAF-UI | `java -jar target/*-executable.jar` in `gmaf-mvr-ui-public` | Swing desktop client |
| REST API | `http://localhost:8242/gmaf/gmafApi` | started *inside* GMAF-UI |
| Swagger UI | `http://localhost:8242/swagger-ui/index.html` | |
| SOAP API | `http://localhost:8481/gmaf/gmafApi` | |
| Web UI | `http://localhost:3000` | `npm start`, reads the REST API |

The key thing to know: **there is no separate backend process.** `de.swa.ui.Main` starts
`de.swa.gmaf.Service` in-process when `launchServer = true` in `conf/gmaf.config`, so the
REST API the web client needs only exists while GMAF-UI is running — `--web-only` gives
you a UI with nothing to talk to.

### Choosing the conf folder (`--basedir`)

`Configuration.reload()` opens `"conf" + File.separatorChar + "gmaf.config"` — a path
relative to the **working directory** — and every data folder named inside it is resolved
the same way. So the working directory is what selects the configuration, and `--basedir`
sets it. `de.swa.ui.Main` does accept a basedir argument, but the field it assigns is
never read anywhere in either repo, so passing one to the jar has no effect.

The jar always comes from the `gmaf-mvr-ui-public` build; only the working directory
changes. A bare name is looked up under `repos/`, anything with a `/` is used as a path,
so you can point it at a data directory outside the workspace entirely.

The default is `repos/gmaf-mvr`. The two obvious candidates are close to complementary,
which is worth knowing before you pick one:

| | `gmaf-mvr` (default) | `gmaf-mvr-ui-public` |
|---|---|---|
| has | `collection`, `conf`, `dictionary`, `resources`, `schema`, `export` | `conf`, `export`, `flows`, `graphcodes`, `mmfgs`, `rdf`, `temp`, `thumbnails` |
| its `gmaf.config` points at | `collection2`, `mmfgs-foo`, `graphcodes`, `flows`, `rdf` — **none of which exist there** | `collection` — which does not exist there; the rest do |

So `gmaf-mvr` carries the data but its config names folders that aren't present, while
`gmaf-mvr-ui-public` has the runtime folders but no collection. The task prints exactly
which folders named in the config are missing before starting, rather than letting GMAF
quietly create empty ones or fail later:

```
== GMAF-UI      gmaf-ui-1.0.3-executable.jar
   basedir      repos/gmaf-mvr  (conf/gmaf.config + data folders)
   !! folders named in conf/gmaf.config that do not exist there:
     collectionPath = collection2
     mmfgRepository = mmfgs-foo
```

Fix that by editing the `conf/gmaf.config` of whichever basedir you use, or by pointing
`--basedir` at a directory that has both the config and the data.

Ports: `serverPort = 8481` (SOAP) comes from `conf/gmaf.config`; the REST port is *not*
in that file and falls back to the `8242` default in `de.swa.ui.Configuration`, which is
what `src/config/config.js` in the web prototype expects. Change one and you must change
the other. The task refuses to start if 8242, 8481 or 3000 is already taken rather than
letting a half-bound stack come up.

`dev` needs `mise run build` to have produced `gmaf-mvr-ui-public/target/*-executable.jar`
(the shaded jar — plain `GMAF-UI.jar` has no `Main-Class` and no dependencies); it says so
if the jar is missing, and installs `node_modules` itself if needed.

Known rough edge, pre-existing and unrelated to the task: `GET /gmaf/gmafApi/openapi.json`
returns 500 (`Illegal attempt to call getOutputStream() after getWriter()`), while
`/swagger-ui/index.html` serves fine.

## Starting over

```sh
mise run reset                      # delete every checkout and clone it again
mise run clean                      # just delete the checkouts
mise run clean -- --dry-run         # list what would be deleted, delete nothing
mise run clean -- --artifacts       # keep the checkouts, drop target/ node_modules/ build/
mise run clean -- --force           # delete even when a repo holds unsaved work
```

`clean` refuses to delete a checkout that holds work you could not get back:
uncommitted changes to tracked files, untracked files, commits that exist on no remote,
or stash entries. It names the repo and the reason, cleans everything else, and exits
non-zero — so `reset`, which depends on it, stops rather than cloning over your work.
Directories in `repos/` that `repos.txt` no longer lists are always treated as stale and
removed.

Two wrinkles it works around, both caused by repos that commit their build output:

- `GMAF` tracks `target/classes/*.class`, so every build leaves it "modified". Changes
  confined to `target/`, `build/`, `node_modules/` and `.venv/` are therefore not treated
  as unsaved work — otherwise `clean` would refuse after every single build.
- For the same reason `--artifacts` skips build directories that are tracked in git, so
  it doesn't turn `GMAF`'s working tree into a list of deleted files.

`setup` and `build` use `npm ci` when a `package-lock.json` is present, since plain
`npm install` rewrites the lockfile and leaves the checkout dirty after every run.

## Layout

```
gmaf-workspace/
├── mise.toml          # pinned toolchains + task definitions
├── repos.txt          # manifest of managed GMAF repositories
├── scripts/           # clone/setup/build/dev/clean/status implementations (bash + one python helper)
│   └── pom-graph.py   # derives the build order from the repos' pom.xml files
└── repos/             # created by `mise run clone`, git-ignored, holds the real checkouts
```

## Notes on the `kind` field

Only `maven` and `node` are in use by the current manifest; the other two are still
supported by the scripts, so a repo of that kind can be added without code changes.

| kind | `mise run setup` | `mise run build` |
|------|------------------|------------------|
| `maven` | `mvn -DskipTests dependency:go-offline` to warm the local `.m2` cache | `mvn install` |
| `node` | `npm install` | `npm run build --if-present` |
| `python-maven` | same Maven step, plus a `.venv` + `pip install -r requirements.txt` when that file exists (for plugins that pair a Java host with a Python model runner) | `mvn install` |
| `cmake` | `cmake ..` into `build/` | `cmake --build`, skipped when the host has no `nvcc` unless `GMAF_FORCE_CUDA=1` |

Adding a `cmake` or `python-maven` repo back also means re-pinning `cmake` in `[tools]`
(dropped from `mise.toml` when `gmaf-cuda` was removed from the manifest).

Most of the Maven repos pin `maven.compiler.source/target` between 10 and 17; JDK 21 can
compile all of them, but if a build insists on an exact toolchain, check that project's
`toolchains.xml`/`settings.xml` (present in a few of the `-public` repos) and register a
matching JDK with `mise use java@<version>` inside that specific checkout.
