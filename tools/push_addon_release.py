#!/usr/bin/env python3
"""Release helper for Echoes of Azeroth addon repos.

This script:
- resolves an addon repo from a short ID
- bumps the .toc patch version (or uses an explicit version)
- commits as the requested author/tagger identity
- pushes the default branch and the new tag
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


AUTHOR_NAME_ENV = "EOA_RELEASE_AUTHOR_NAME"
AUTHOR_EMAIL_ENV = "EOA_RELEASE_AUTHOR_EMAIL"
VERSION_RE = re.compile(r"^(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$")
TOC_VERSION_RE = re.compile(r"^(## Version:\s*)(\d+\.\d+\.\d+)\s*$", re.MULTILINE)


@dataclass(frozen=True)
class AddonRepo:
    key: str
    label: str
    root: Path
    toc_name: str

    @property
    def toc_path(self) -> Path:
        return self.root / self.toc_name


def build_repos() -> dict[str, AddonRepo]:
    core_root = Path(__file__).resolve().parents[1]
    parent = core_root.parent

    repos = {
        "core": AddonRepo("core", "EchoesOfAzeroth", core_root, "EchoesOfAzeroth.toc"),
        "quelthalas": AddonRepo(
            "quelthalas",
            "EchoesOfAzeroth_QuelThalas",
            parent / "EchoesOfAzeroth_QuelThalas",
            "EchoesOfAzeroth_QuelThalas.toc",
        ),
        "zulaman": AddonRepo(
            "zulaman",
            "EchoesOfAzeroth_ZulAman",
            parent / "EchoesOfAzeroth_ZulAman",
            "EchoesOfAzeroth_ZulAman.toc",
        ),
    }
    aliases = {
        "echoesofazeroth": repos["core"],
        "qt": repos["quelthalas"],
        "za": repos["zulaman"],
    }
    return {**repos, **aliases}


def run_git(repo: Path, *args: str, env: dict[str, str] | None = None) -> str:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        env=merged_env,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed in {repo}:\n{result.stdout}{result.stderr}".rstrip()
        )
    return result.stdout.strip()


def get_git_config(repo: Path, key: str) -> str | None:
    result = subprocess.run(
        ["git", "config", "--local", "--get", key],
        cwd=repo,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bump addon version, commit, push branch, and push tag."
    )
    parser.add_argument(
        "addon",
        help="Addon key: core, quelthalas, zulaman (aliases: echoesofazeroth, qt, za).",
    )
    parser.add_argument(
        "--version",
        help="Explicit version to release. Defaults to bumping the patch version from the .toc.",
    )
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="Allow running with a dirty worktree. Disabled by default for release safety.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate inputs and print the planned release without changing anything.",
    )
    return parser.parse_args()


def parse_version(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.match(version)
    if not match:
        raise ValueError(f"Invalid semantic version: {version}")
    return tuple(int(match.group(name)) for name in ("major", "minor", "patch"))


def bump_patch(version: str) -> str:
    major, minor, patch = parse_version(version)
    return f"{major}.{minor}.{patch + 1}"


def read_toc_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = TOC_VERSION_RE.search(text)
    if not match:
        raise RuntimeError(f"Could not find `## Version:` in {path}")
    return match.group(2)


def read_head_toc_version(repo: AddonRepo) -> str | None:
    result = subprocess.run(
        ["git", "show", f"HEAD:{repo.toc_name}"],
        cwd=repo.root,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    match = TOC_VERSION_RE.search(result.stdout)
    return match.group(2) if match else None


def write_toc_version(path: Path, version: str) -> None:
    text = path.read_text(encoding="utf-8")
    updated, count = TOC_VERSION_RE.subn(rf"\g<1>{version}", text, count=1)
    if count != 1:
        raise RuntimeError(f"Could not update `## Version:` in {path}")
    path.write_text(updated, encoding="utf-8")


def require_clean_worktree(repo: Path) -> None:
    status = run_git(repo, "status", "--porcelain")
    if status:
        raise RuntimeError(
            "Working tree is not clean.\n"
            "Commit or stash changes first, or rerun with --allow-dirty if you really mean it."
        )


def is_worktree_dirty(repo: Path) -> bool:
    return bool(run_git(repo, "status", "--porcelain"))


def is_file_modified(repo: Path, relative_path: str) -> bool:
    return bool(run_git(repo, "diff", "--name-only", "--", relative_path))


def get_current_branch(repo: Path) -> str:
    return run_git(repo, "branch", "--show-current")


def get_default_branch(repo: Path) -> str:
    ref = run_git(repo, "symbolic-ref", "refs/remotes/origin/HEAD")
    prefix = "refs/remotes/origin/"
    if not ref.startswith(prefix):
        raise RuntimeError(f"Unexpected origin HEAD ref: {ref}")
    return ref[len(prefix) :]


def ensure_on_default_branch(repo: Path) -> str:
    current = get_current_branch(repo)
    default = get_default_branch(repo)
    if current != default:
        raise RuntimeError(
            f"Current branch is `{current}` but origin default branch is `{default}`.\n"
            "Checkout the default branch before releasing."
        )
    return default


def ensure_tag_absent(repo: Path, tag_name: str) -> None:
    local = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag_name}"],
        cwd=repo,
        text=True,
        capture_output=True,
    )
    if local.returncode == 0:
        raise RuntimeError(f"Tag `{tag_name}` already exists locally.")

    remote = subprocess.run(
        ["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag_name}"],
        cwd=repo,
        text=True,
        capture_output=True,
    )
    if remote.returncode != 0:
        raise RuntimeError(f"Could not query remote tags:\n{remote.stdout}{remote.stderr}".rstrip())
    if remote.stdout.strip():
        raise RuntimeError(f"Tag `{tag_name}` already exists on origin.")


def stage_release_changes(repo: AddonRepo) -> None:
    run_git(repo.root, "add", "-A")


def resolve_release_identity(repo: AddonRepo) -> tuple[str, str]:
    name = os.environ.get(AUTHOR_NAME_ENV) or get_git_config(repo.root, "user.name")
    email = os.environ.get(AUTHOR_EMAIL_ENV) or get_git_config(repo.root, "user.email")
    if not name or not email:
        raise RuntimeError(
            "Could not resolve release identity.\n"
            f"Set local git config `user.name` / `user.email` in `{repo.root}` "
            f"or export `{AUTHOR_NAME_ENV}` and `{AUTHOR_EMAIL_ENV}`."
        )
    return name, email


def commit_and_tag(repo: AddonRepo, version: str, author_name: str, author_email: str) -> None:
    env = {
        "GIT_AUTHOR_NAME": author_name,
        "GIT_AUTHOR_EMAIL": author_email,
        "GIT_COMMITTER_NAME": author_name,
        "GIT_COMMITTER_EMAIL": author_email,
    }
    tag_name = f"v{version}"
    commit_message = f"release: bump {repo.label} to {tag_name}"

    run_git(repo.root, "commit", "-m", commit_message, env=env)
    run_git(repo.root, "tag", "-a", tag_name, "-m", tag_name, env=env)


def push_release(repo: Path, branch: str, version: str) -> None:
    tag_name = f"v{version}"
    run_git(repo, "push", "origin", branch)
    run_git(repo, "push", "origin", tag_name)


def main() -> int:
    args = parse_args()
    repos = build_repos()
    repo = repos.get(args.addon.strip().lower())
    if repo is None:
        valid = "core, quelthalas, zulaman"
        raise RuntimeError(f"Unknown addon `{args.addon}`. Expected one of: {valid}")

    if not repo.root.is_dir():
        raise RuntimeError(f"Repo directory does not exist: {repo.root}")
    if not repo.toc_path.is_file():
        raise RuntimeError(f".toc file does not exist: {repo.toc_path}")

    current_version = read_toc_version(repo.toc_path)
    head_version = read_head_toc_version(repo)
    worktree_dirty = is_worktree_dirty(repo.root)
    toc_is_modified = is_file_modified(repo.root, repo.toc_name)

    if args.version:
        target_version = args.version
    elif toc_is_modified and head_version and current_version != head_version:
        target_version = current_version
    else:
        target_version = bump_patch(current_version)
    parse_version(target_version)

    if target_version == current_version and not worktree_dirty:
        raise RuntimeError(
            f"Target version `{target_version}` matches current version in `{repo.toc_path.name}`."
        )

    if not args.allow_dirty:
        require_clean_worktree(repo.root)

    branch = ensure_on_default_branch(repo.root)
    tag_name = f"v{target_version}"
    ensure_tag_absent(repo.root, tag_name)
    author_name, author_email = resolve_release_identity(repo)

    if args.dry_run:
        print(f"Dry run for {repo.label}")
        print(f"Repo: {repo.root}")
        print(f"HEAD version: {head_version or 'unknown'}")
        print(f"Current version: {current_version}")
        print(f"Target version: {target_version}")
        print(f"Branch: {branch}")
        print(f"Tag: {tag_name}")
        print(f"Author/Tagger: {author_name} <{author_email}>")
        return 0

    if target_version != current_version:
        write_toc_version(repo.toc_path, target_version)
    try:
        stage_release_changes(repo)
        commit_and_tag(repo, target_version, author_name, author_email)
        push_release(repo.root, branch, target_version)
    except Exception:
        # Leave changes in place for inspection if something fails after bumping.
        raise

    print(f"Released {repo.label} {target_version}")
    print(f"Repo: {repo.root}")
    print(f"Branch: {branch}")
    print(f"Tag: {tag_name}")
    print(f"Author/Tagger: {author_name} <{author_email}>")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI failure path
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
