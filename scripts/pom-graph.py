#!/usr/bin/env python3
"""Derives the build order of the managed repos from their pom.xml files.

Reads repos.txt, parses the pom.xml of every cloned Maven-flavoured repo, and
works out which repos depend on artifacts that other repos in this workspace
produce. Emits the repos in topological order (dependencies first).

Output formats:
  --format=machine  (default)  name|kind|comma-separated direct deps
  --format=human               readable order + resolved/unresolved edges
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
REPOS_FILE = WORKSPACE_ROOT / "repos.txt"
REPOS_DIR = WORKSPACE_ROOT / "repos"

# Repo kinds that are built by Maven and therefore carry a pom.xml.
MAVEN_KINDS = {"maven", "python-maven"}

PROPERTY_RE = re.compile(r"\$\{([^}]+)\}")


def strip_ns(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


def child(elem, name):
    """First direct child with the given (namespace-insensitive) tag."""
    for sub in elem:
        if strip_ns(sub.tag) == name:
            return sub
    return None


def child_text(elem, name):
    sub = child(elem, name)
    if sub is None or sub.text is None:
        return None
    return sub.text.strip() or None


def findall_deep(elem, name):
    return [sub for sub in elem.iter() if strip_ns(sub.tag) == name]


class Repo:
    def __init__(self, name, url, kind, branch, description):
        self.name = name
        self.url = url
        self.kind = kind
        self.branch = branch
        self.description = description
        self.path = REPOS_DIR / name
        self.cloned = (self.path / ".git").is_dir()
        self.coords = None            # (groupId, artifactId, version) it produces
        self.requires = []            # (groupId, artifactId, version) it consumes
        self.deps = []                # repo names, resolved
        self.notes = []               # human-readable resolution warnings

    @property
    def is_maven(self):
        return self.kind in MAVEN_KINDS


def read_manifest():
    repos = []
    for line in REPOS_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) < 5:
            print(f"warning: malformed repos.txt line: {line}", file=sys.stderr)
            continue
        repos.append(Repo(*fields[:5]))
    return repos


def interpolate(value, properties):
    """Resolve ${...} placeholders one level deep; leave unknown ones intact."""
    if value is None:
        return None

    def sub(match):
        return properties.get(match.group(1), match.group(0))

    return PROPERTY_RE.sub(sub, value)


def parse_pom(repo):
    """Fill in repo.coords and repo.requires from its pom.xml."""
    pom = repo.path / "pom.xml"
    if not pom.is_file():
        repo.notes.append("no pom.xml found")
        return

    try:
        root = ET.parse(pom).getroot()
    except ET.ParseError as exc:
        repo.notes.append(f"pom.xml could not be parsed: {exc}")
        return

    parent = child(root, "parent")
    group = child_text(root, "groupId") or (child_text(parent, "groupId") if parent is not None else None)
    artifact = child_text(root, "artifactId")
    version = child_text(root, "version") or (child_text(parent, "version") if parent is not None else None)

    properties = {}
    props = child(root, "properties")
    if props is not None:
        for sub in props:
            if sub.text and sub.text.strip():
                properties[strip_ns(sub.tag)] = sub.text.strip()
    if version:
        properties.setdefault("project.version", version)
    if group:
        properties.setdefault("project.groupId", group)

    if artifact:
        repo.coords = (group, artifact, version)

    seen = set()

    def want(g, a, v):
        g = interpolate(g, properties)
        a = interpolate(a, properties)
        v = interpolate(v, properties)
        if not g or not a:
            return
        key = (g, a, v)
        if key in seen:
            return
        seen.add(key)
        repo.requires.append(key)

    # An inherited parent POM is a build dependency too.
    if parent is not None:
        want(child_text(parent, "groupId"), child_text(parent, "artifactId"), child_text(parent, "version"))

    # Covers <dependencies> and <dependencyManagement> alike.
    for dep in findall_deep(root, "dependency"):
        want(child_text(dep, "groupId"), child_text(dep, "artifactId"), child_text(dep, "version"))


def resolve_edges(repos):
    by_ga = {}
    by_gav = {}
    for repo in repos:
        if not repo.coords:
            continue
        group, artifact, version = repo.coords
        by_ga.setdefault((group, artifact), []).append(repo.name)
        by_gav.setdefault((group, artifact, version), []).append(repo.name)

    for repo in repos:
        for group, artifact, version in repo.requires:
            candidates = by_ga.get((group, artifact))
            if not candidates:
                continue  # third-party dependency, Maven Central's problem

            exact = by_gav.get((group, artifact, version), [])
            exact = [name for name in exact if name != repo.name]
            others = [name for name in candidates if name != repo.name]

            if len(exact) == 1:
                provider = exact[0]
            elif len(others) == 1:
                provider = others[0]
                produced = next(r.coords[2] for r in repos if r.name == provider)
                repo.notes.append(
                    f"wants {group}:{artifact}:{version} but {provider} produces {produced} "
                    "— building it will not satisfy this dependency, Maven will look in ~/.m2 "
                    "or the remote repository instead"
                )
            elif not others:
                continue
            else:
                repo.notes.append(
                    f"{group}:{artifact}:{version} is ambiguous — produced by {', '.join(sorted(others))}; "
                    "no build-order edge inferred"
                )
                continue

            if provider not in repo.deps:
                repo.deps.append(provider)


def topo_sort(repos):
    """Kahn's algorithm. Maven repos win ties so Java builds before JS/native."""
    order_index = {repo.name: i for i, repo in enumerate(repos)}
    by_name = {repo.name: repo for repo in repos}
    pending = {repo.name: set(repo.deps) for repo in repos}
    dependents = {repo.name: [] for repo in repos}
    for repo in repos:
        for dep in repo.deps:
            dependents[dep].append(repo.name)

    def sort_key(name):
        return (0 if by_name[name].is_maven else 1, order_index[name])

    ready = sorted([n for n, deps in pending.items() if not deps], key=sort_key)
    ordered = []
    while ready:
        name = ready.pop(0)
        ordered.append(name)
        for dependent in dependents[name]:
            pending[dependent].discard(name)
            if not pending[dependent] and dependent not in ordered and dependent not in ready:
                ready.append(dependent)
        ready.sort(key=sort_key)

    cyclic = [n for n in pending if n not in ordered]
    if cyclic:
        cyclic.sort(key=sort_key)
        print(
            f"warning: dependency cycle among {', '.join(cyclic)}; "
            "appending them in manifest order",
            file=sys.stderr,
        )
        ordered.extend(cyclic)

    return [by_name[name] for name in ordered]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("machine", "human"), default="machine")
    parser.add_argument(
        "--include-uncloned",
        action="store_true",
        help="keep repos that have not been cloned yet (they are skipped by default)",
    )
    args = parser.parse_args()

    repos = read_manifest()
    for repo in repos:
        if repo.is_maven and repo.cloned:
            parse_pom(repo)

    resolve_edges(repos)
    ordered = topo_sort(repos)
    if not args.include_uncloned:
        ordered = [repo for repo in ordered if repo.cloned]

    if args.format == "machine":
        for repo in ordered:
            print(f"{repo.name}|{repo.kind}|{','.join(repo.deps)}")
        return 0

    width = max((len(r.name) for r in ordered), default=0)
    print("Build order (dependencies first):")
    for position, repo in enumerate(ordered, start=1):
        coords = ":".join(part or "?" for part in repo.coords) if repo.coords else "-"
        print(f"  {position:>2}. {repo.name:<{width}}  {repo.kind:<13} {coords}")
        if repo.deps:
            print(f"      {'needs:':<6} {', '.join(repo.deps)}")

    notes = [(repo.name, note) for repo in ordered for note in repo.notes]
    if notes:
        print("\nResolution notes:")
        for name, note in notes:
            print(f"  - {name}: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
