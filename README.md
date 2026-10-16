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
- For `gmaf-cuda`: a CUDA toolkit + CUDA-capable GPU/driver installed on the host — mise
  manages `cmake` for you, but the CUDA compiler/runtime itself is a system-level install
  mise does not manage.

## Quick start

```sh
mise trust        # first time only, approves this repo's mise.toml
mise install      # installs the pinned Java/Maven/Node/Python/CMake versions
mise run clone    # clones every repo in repos.txt into ./repos
mise run setup    # resolves Maven deps / npm installs / python venvs for each repo
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
| cmake  | latest  |

## Repositories managed here

| repo | kind | purpose |
|------|------|---------|
| [GMAF](https://github.com/marquies/GMAF) | maven | Core framework: the Multimedia Feature Vector Graph (MMFG) model |
| [gmaf-dummy](https://github.com/marquies/gmaf-dummy) | maven | Minimal plugin skeleton/example for writing new GMAF plugins |
| [gmaf-cuda](https://github.com/marquies/gmaf-cuda) | cmake | CUDA/C++ native feature-extraction plugin |
| [gmaf-mvr](https://github.com/marquies/gmaf-mvr) | maven | GMAF-MVR core (Metaverse Video Recording pipeline) |
| [gmaf-mvr-api](https://github.com/marquies/gmaf-mvr-api) | maven | GMAF-MVR REST API |
| [gmaf-mvr-container](https://github.com/marquies/gmaf-mvr-container) | maven | GMAF-MVR containerized runner |
| [gmaf-mvr-core-plugins](https://github.com/marquies/gmaf-mvr-core-plugins) | maven | GMAF-MVR core feature-extraction plugins |
| [gmaf-mvr-rnd](https://github.com/marquies/gmaf-mvr-rnd) | maven | GMAF-MVR research & development sandbox |
| [gmaf-mvr-semantics-public](https://github.com/marquies/gmaf-mvr-semantics-public) | maven | GMAF-MVR semantics/explainability module |
| [gmaf-mvr-service-public](https://github.com/marquies/gmaf-mvr-service-public) | maven | GMAF-MVR service layer |
| [gmaf-mvr-ui-public](https://github.com/marquies/gmaf-mvr-ui-public) | maven | GMAF-MVR UI backend |
| [gmaf-mvr-webui-prototype](https://github.com/marquies/gmaf-mvr-webui-prototype) | node | GMAF-MVR React web UI prototype |
| [avatar-detector-gmaf-plugin](https://github.com/marquies/avatar-detector-gmaf-plugin) | python-maven | Avatar detector GMAF plugin (Java + Python/YOLOv7) |

The authoritative list lives in [`repos.txt`](./repos.txt) — one line per repo:
`name|git_url|kind|default_branch|description`. Add a new GMAF repo by appending a line
there; no script changes are needed for the common kinds (`maven`, `node`, `cmake`,
`python-maven`).

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
├── scripts/           # clone/setup/status/list implementations (plain bash)
└── repos/             # created by `mise run clone`, git-ignored, holds the real checkouts
```

## Notes on the `kind` field

- `maven`   — runs `mvn -DskipTests dependency:go-offline` to warm the local `.m2` cache.
- `node`    — runs `npm install`.
- `python-maven` — same Maven step, plus a `.venv` + `pip install -r requirements.txt`
  when that file exists (several GMAF plugins mix a Java host with a Python model runner).
- `cmake`   — runs `cmake ..` into `build/`; still requires a working CUDA toolchain on
  the machine for `gmaf-cuda` specifically.

Most of the Maven repos pin `maven.compiler.source/target` between 10 and 17; JDK 21 can
compile all of them, but if a build insists on an exact toolchain, check that project's
`toolchains.xml`/`settings.xml` (present in a few of the `-public` repos) and register a
matching JDK with `mise use java@<version>` inside that specific checkout.
