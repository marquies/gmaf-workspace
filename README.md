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
which Maven rejects outright with *dependencies.dependency.(groupId:artifactId:type:
classifier) must be unique*. The fix applied locally: drop the hardcoded declaration and
raise `<jackson.version>` to `2.18.2`, so `jackson-databind`, `jackson-core`, and
`jackson-annotations` all move in lockstep off the one property.

⚠️ **That fix lives in `repos/`, which is git-ignored** — it is not tracked by this
workspace and a fresh `mise run clone` (or any other machine) gets the broken POM back.
It needs a commit in the upstream `gmaf-mvr-service-public` repository to become
permanent.

The `settings.xml`/`toolchains.xml` files checked into a few repos point at GitHub Actions
paths (`/opt/hostedtoolcache/...`), so the build deliberately does **not** pass them to
Maven.

## Day-to-day commands

```sh
mise run pull                       # git pull --ff-only everywhere
mise run status                     # git status -sb everywhere
mise run exec -- git log -1 --oneline   # run any command in every cloned repo
```

## Layout

```
gmaf-workspace/
├── mise.toml          # pinned toolchains + task definitions
├── repos.txt          # manifest of managed GMAF repositories
├── scripts/           # clone/setup/build/status/list implementations (bash + one python helper)
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
