#!/usr/bin/env python3
"""Generates an IntelliJ IDEA project for the whole workspace.

Everything is derived from repos.txt and the cloned checkouts, so re-running
after adding a repo keeps the project in sync.

Writes, at the workspace root:
  .idea/misc.xml                  every Maven repo linked as a Maven project
  .idea/vcs.xml                   each checkout registered as its own Git root
  .idea/runConfigurations/*.xml   GMAF-UI and the web UI dev server
  .idea/.name                     project name in the IDE title bar

Existing files are left alone unless --force is given.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
REPOS_FILE = WORKSPACE_ROOT / "repos.txt"
REPOS_DIR = WORKSPACE_ROOT / "repos"
IDEA_DIR = WORKSPACE_ROOT / ".idea"

MAVEN_KINDS = {"maven", "python-maven"}

# The UI is launched from gmaf-mvr, not from its own checkout: Configuration
# reads conf/gmaf.config relative to the working directory. Mirrors dev.sh.
UI_REPO = "gmaf-mvr-ui-public"
UI_MAIN_CLASS = "de.swa.ui.Main"
UI_BASEDIR = "gmaf-mvr"
WEB_REPO = "gmaf-mvr-webui-prototype"


def read_manifest():
    repos = []
    for line in REPOS_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) >= 5:
            name, _url, kind = fields[0], fields[1], fields[2]
            repos.append((name, kind, (REPOS_DIR / name)))
    return repos


def mise_java_home() -> str | None:
    try:
        out = subprocess.run(
            ["mise", "where", "java"], capture_output=True, text=True, cwd=WORKSPACE_ROOT, timeout=30
        )
        return out.stdout.strip() or None
    except Exception:
        return None


def jdk_version() -> str:
    """The major version pinned in mise.toml, e.g. '21'."""
    for line in (WORKSPACE_ROOT / "mise.toml").read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("java"):
            value = line.split("=", 1)[1].strip().strip('"').strip("'")
            return value.split("#")[0].strip().strip('"')
    return "21"


def misc_xml(maven_poms, jdk):
    entries = "\n".join(
        f'        <option value="$PROJECT_DIR$/{p}" />' for p in maven_poms
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="MavenProjectsManager">
    <option name="originalFiles">
      <list>
{entries}
      </list>
    </option>
  </component>
  <component name="ProjectRootManager" version="2" languageLevel="JDK_{jdk}" default="true" project-jdk-name="{jdk}" project-jdk-type="JavaSDK">
    <output url="file://$PROJECT_DIR$/out" />
  </component>
</project>
"""


def vcs_xml(repo_dirs):
    mappings = "\n".join(
        f'    <mapping directory="$PROJECT_DIR$/{d}" vcs="Git" />' for d in repo_dirs
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="VcsDirectoryMappings">
    <mapping directory="$PROJECT_DIR$" vcs="Git" />
{mappings}
  </component>
</project>
"""


def ui_run_config(module_name):
    return f"""<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="GMAF-UI" type="Application" factoryName="Application">
    <option name="MAIN_CLASS_NAME" value="{UI_MAIN_CLASS}" />
    <module name="{module_name}" />
    <option name="WORKING_DIRECTORY" value="$PROJECT_DIR$/repos/{UI_BASEDIR}" />
    <method v="2">
      <option name="Make" enabled="true" />
    </method>
  </configuration>
</component>
"""


def web_run_config():
    return f"""<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="Web UI (npm start)" type="js.build_tools.npm" nameIsGenerated="false">
    <package-json value="$PROJECT_DIR$/repos/{WEB_REPO}/package.json" />
    <command value="run" />
    <scripts>
      <script value="start" />
    </scripts>
    <node-interpreter value="project" />
    <envs>
      <env name="BROWSER" value="none" />
    </envs>
    <method v="2" />
  </configuration>
</component>
"""


def write(path: Path, content: str, force: bool, dry_run: bool, written, skipped):
    rel = path.relative_to(WORKSPACE_ROOT)
    if path.exists() and not force:
        skipped.append(str(rel))
        return
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    written.append(str(rel))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="overwrite files that already exist")
    parser.add_argument("--dry-run", action="store_true", help="show what would be written")
    args = parser.parse_args()

    repos = read_manifest()
    cloned = [(n, k, p) for n, k, p in repos if (p / ".git").is_dir()]
    if not cloned:
        print("No repositories cloned yet — run 'mise run clone' first.")
        return 1

    maven_poms = [f"repos/{n}/pom.xml" for n, k, p in cloned if k in MAVEN_KINDS and (p / "pom.xml").is_file()]
    repo_dirs = [f"repos/{n}" for n, _k, _p in cloned]
    jdk = jdk_version()

    written, skipped = [], []
    write(IDEA_DIR / "misc.xml", misc_xml(maven_poms, jdk), args.force, args.dry_run, written, skipped)
    write(IDEA_DIR / "vcs.xml", vcs_xml(repo_dirs), args.force, args.dry_run, written, skipped)
    write(IDEA_DIR / ".name", "gmaf-workspace\n", args.force, args.dry_run, written, skipped)

    ui = next((p for n, _k, p in cloned if n == UI_REPO), None)
    if ui is not None:
        # The IDEA module takes its name from the artifactId, not the directory.
        module = "gmaf-ui"
        for line in (ui / "pom.xml").read_text(encoding="utf-8").splitlines():
            if "<artifactId>" in line:
                module = line.split("<artifactId>")[1].split("</artifactId>")[0].strip()
                break
        write(IDEA_DIR / "runConfigurations" / "GMAF_UI.xml", ui_run_config(module),
              args.force, args.dry_run, written, skipped)

    if any(n == WEB_REPO for n, _k, _p in cloned):
        write(IDEA_DIR / "runConfigurations" / "Web_UI__npm_start_.xml", web_run_config(),
              args.force, args.dry_run, written, skipped)

    print(f"Maven projects linked ({len(maven_poms)}):")
    for p in maven_poms:
        print(f"  {p}")
    print(f"\nGit roots registered: {len(repo_dirs) + 1} (workspace + {len(repo_dirs)} checkouts)")

    if written:
        print("\nwritten:" if not args.dry_run else "\nwould write:")
        for w in written:
            print(f"  {w}")
    if skipped:
        print("\nkept (already present, use --force to overwrite):")
        for s in skipped:
            print(f"  {s}")

    java_home = mise_java_home()
    print(f"\nProject SDK is set to the name '{jdk}'. IDEA resolves that against its own")
    print("SDK table, which lives in your JetBrains config rather than this project, so")
    print("if it reports 'No SDK' point it once at the JDK mise manages:")
    print(f"  {java_home or '(run: mise where java)'}")
    print("  File > Project Structure > SDKs > + > Add JDK")

    if args.dry_run:
        print("\nDry run — nothing written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
