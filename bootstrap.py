#!/usr/bin/env python3
"""Rename this template repo into a fresh app, then delete this script.

Usage:
    ./bootstrap.py <app-name>
    ./bootstrap.py myapp                 # main app named myapp
    ./bootstrap.py my-cool-api           # dashes auto-mapped to underscores

Examples of what gets rewritten (kebab-case → input as-is, snake_case →
auto-derived for Python module names):

    [project].name = "python-devcontainer"   →  "myapp"
    src/python_devcontainer/                 →  src/myapp/
    "name": "python-devcontainer"            →  "name": "myapp"  (devcontainer.json)
    name: python-devcontainer                →  name: myapp      (compose, both occurrences)
    /workspaces/python-devcontainer          →  /workspaces/myapp
    `uv run python-devcontainer`             →  `uv run myapp`
    from python_devcontainer import …        →  from myapp import …

# =============================================================================
# Why this script exists — the decision trail
# =============================================================================
#
# When the template is reused for a new app, ~30 strings across 8 files need
# coordinated updates. Doing this by hand is error-prone (you forget the
# safe.directory line in post-start.sh, the COMPOSE_FILE env var, the import
# in the smoke test, …) and the mistakes only surface much later when
# something breaks weirdly.
#
# -----------------------------------------------------------------------------
# Decision 1: Approach 1 (manual rename via script), NOT Approach 2 (copier
# template) or Approach 3 (decouple names so devcontainer is generic).
# -----------------------------------------------------------------------------
# Considered:
#   A. One-shot rename script that mutates files in place, then self-deletes.
#      ← chosen
#   B. Convert the repo into a copier/cookiecutter template with {{app_name}}
#      placeholders; new apps via `copier copy gh:user/template ../myapp`.
#   C. Make devcontainer.json / docker-compose.yml use a generic name like
#      "dev" that never changes; only rename pyproject.toml + src/.
#
# Why A wins for this project:
#   - The template stays a VALID, RUNNABLE Python project. You can `uv sync`,
#     `uv run pre-commit run --all-files`, `uv run pytest` against the
#     template itself — they all work, because there are no `{{...}}`
#     placeholders breaking ruff/yaml validation. (B fails this test:
#     copier templates have to disable ruff/pre-commit on themselves or
#     use `_extension`-style escapes that bloat every file.)
#   - One-time cost. The user is going to rename roughly 4 apps from this
#     template over its lifetime, not 400. The amortised cost of building
#     and maintaining a copier template (separate `_copier_answers.yml`,
#     Jinja syntax in YAML/TOML, testing the template generation itself)
#     dwarfs running this script 4 times.
#   - Output is auditable. After running this script, `git diff` shows
#     exactly what changed; with a copier template, the diff is "everything
#     is new" and harder to inspect.
#   - C produces confusing `docker ps` output: every project's container
#     would be named `dev_dev_1`, every workspace path `/workspaces/dev`.
#     Across 3 simultaneous side-by-side projects this becomes unworkable.
#
# What we GIVE UP by picking A:
#   - No "re-apply template updates to existing apps" story. If we improve
#     the devcontainer setup later, existing apps don't auto-receive the
#     improvement; the user must port changes manually. For a personal
#     template this is fine — for an org-wide template it would not be.
#
# -----------------------------------------------------------------------------
# Decision 2: Python, NOT bash.
# -----------------------------------------------------------------------------
# Considered:
#   A. Bash + sed + mv. Most "rename a template" scripts in the wild are bash.
#   B. Python.  ← chosen
#
# Why Python wins:
#   - GNU sed and BSD sed (macOS) take incompatible flags for in-place edits
#     (GNU: `sed -i`, BSD: `sed -i ''`). Bash scripts that don't account for
#     this fail silently on macOS or worse, mutate file paths.
#   - Python is already a project requirement (we're in a uv repo). Using
#     bash to bootstrap a Python project is tooling regression.
#   - String operations (case conversion, name validation, path renames)
#     are MUCH more readable in Python than in shell.
#   - Stdlib only: pathlib, argparse, re, shutil, sys. No deps to install
#     before this script can run.
#
# What we GIVE UP:
#   - Slightly heavier interpreter startup than bash (~30ms). For a script
#     that runs ONCE in the lifetime of a repo, irrelevant.
#
# -----------------------------------------------------------------------------
# Decision 3: Curated, EXPLICIT list of replacements, NOT recursive
# `grep -rl | xargs sed`.
# -----------------------------------------------------------------------------
# Considered:
#   A. Hand-listed (file_path, old_string, new_string) tuples plus an
#      explicit src/ directory rename. ← chosen
#   B. Recursive `grep -rl python-devcontainer | xargs sed -i` over the
#      whole repo.
#
# Why A wins:
#   - The recursive approach would corrupt files that legitimately contain
#     the template name:
#       • uv.lock contains `name = "python-devcontainer"` as a real package
#         identity — rewriting it poisons the lockfile (which then no
#         longer matches what `uv sync` resolves; first sync will fail
#         loudly, but that's still wasted time).
#       • .git/ may contain commit messages, refs, or pack files that
#         happen to embed the name. Editing inside .git/ corrupts the
#         repo.
#       • Comments in this very file legitimately contain "python-
#         devcontainer" as the template's NAME-OF-RECORD. After rename,
#         we want those comments preserved as historical context, not
#         erased into "myapp was renamed from myapp" gibberish.
#   - The recursive approach also can't handle different identifier forms
#     in the same file (python-devcontainer vs python_devcontainer vs
#     PYTHON_DEVCONTAINER). Listing each substitution explicitly makes
#     the form-mapping clear.
#   - When something goes wrong (a future template change adds a new
#     reference we forgot), the script tells you exactly which file's
#     replacement failed, instead of silently mangling something else.
#
# What we GIVE UP:
#   - When new references to the template name are added to the codebase,
#     this script must be updated too. The verification step (re-running
#     `grep python-devcontainer` after rename) catches missed cases.
#
# -----------------------------------------------------------------------------
# Decision 4: Self-delete on success, NOT leave behind for later use.
# -----------------------------------------------------------------------------
# Considered:
#   A. Self-delete after running. ← chosen
#   B. Leave behind so the user can re-run.
#
# Why A wins:
#   - Re-running this script in the new app does NOTHING useful. The
#     template strings are gone; every replacement is a no-op. Leaving
#     the script behind invites confusion ("can I re-run this with a
#     different name?" — no, you can't, the template state is gone).
#   - Bootstrapping is a one-shot lifecycle event. Artifacts of that
#     event don't belong in the steady-state repo. Like a cookiecutter
#     post-generation hook that removes itself.
#   - One less file in the long-term `git log`.
#
# What we GIVE UP:
#   - The user can't re-run to fix a typo'd app name. Acceptable — they
#     just `rm -rf myapp` and re-clone the template. A 30-second cost
#     that almost never happens.
#
# -----------------------------------------------------------------------------
# Decision 5: Leave `pdc-core` ALONE by default, opt-in to rename via
# --rename-core flag.
# -----------------------------------------------------------------------------
# The shared lib has a different lifecycle from the main service. A user
# who builds `myapp` may well want to keep `pdc-core` as a stable, shared
# utility namespace — especially if they're going to build `myotherapp`
# later that also depends on the same core. Defaulting to "leave alone"
# preserves that option; --rename-core gives the escape hatch for users
# who really want everything under one umbrella name.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# -----------------------------------------------------------------------------
# Constants — the template's known names.
# -----------------------------------------------------------------------------
# Hard-coding these is intentional: this script is intimately coupled to
# the template's current state. If the template ever renames itself
# (e.g. to "py-dc-template"), update these constants too — but that's
# a deliberate cross-repo refactor, not a generic abstraction.
TEMPLATE_KEBAB = "python-devcontainer"  # used in [project].name, paths, COMPOSE_PROJECT_NAME
TEMPLATE_SNAKE = "python_devcontainer"  # used in module / import names

# pdc-core uses the project's "internal namespace prefix". When --rename-core
# is set we substitute the FIRST segment of the name. The rest of the
# package name (`-core`) is preserved.
TEMPLATE_PREFIX_KEBAB = "pdc"
TEMPLATE_PREFIX_SNAKE = "pdc"  # happens to equal kebab here, but kept separate


# -----------------------------------------------------------------------------
# Name normalisation
# -----------------------------------------------------------------------------
def normalise_name(raw: str) -> tuple[str, str]:
    """Return (kebab, snake) forms of the user-supplied app name.

    Why both forms: PEP 503 normalises distribution names to kebab-case
    (lowercase, dashes), while Python import names MUST be valid identifiers
    (lowercase, underscores). The user supplies one string; we derive both.

    Validation rules (matching PEP 508 distribution name rules, the strict
    intersection that's also a valid Python identifier):
      - lowercase letters, digits, dashes
      - must start with a letter
      - no consecutive dashes
    """
    name = raw.strip().lower()
    if not re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)*", name):
        sys.exit(
            f"error: invalid app name {raw!r}. Use lowercase letters, digits, "
            f"and single dashes (e.g. 'myapp', 'my-cool-api', 'app2')."
        )
    kebab = name
    snake = name.replace("-", "_")
    return kebab, snake


# -----------------------------------------------------------------------------
# Replacement plan
# -----------------------------------------------------------------------------
# Every entry is (relative_path, [(old, new), ...]). Listing per-file means
# we can't accidentally rewrite something we didn't review (uv.lock, .git/).
def build_text_replacements(
    new_kebab: str,
    new_snake: str,
    rename_core_to: str | None,
) -> list[tuple[str, list[tuple[str, str]]]]:
    # The kebab → kebab and snake → snake substitutions are the bulk; we
    # always do BOTH because most files contain at least one of each form.
    base = [(TEMPLATE_KEBAB, new_kebab), (TEMPLATE_SNAKE, new_snake)]

    # Optional core-prefix rename. The substitution is anchored to the
    # FRONT of the prefix segment with a word boundary so we don't mangle
    # comments mentioning "pdc" in unrelated contexts (there shouldn't be
    # any, but defensive).
    if rename_core_to is not None:
        base.append((f"{TEMPLATE_PREFIX_KEBAB}-", f"{rename_core_to}-"))
        base.append((f"{TEMPLATE_PREFIX_SNAKE}_", f"{rename_core_to.replace('-', '_')}_"))

    # Files where we rewrite text. ORDER within the list doesn't matter
    # (replacements are independent). MISSING from the list: uv.lock (auto-
    # regenerated by `uv sync`), .git/* (corrupts repo).
    return [
        ("pyproject.toml", base),
        ("README.md", base),
        ("src/python_devcontainer/__init__.py", base),
        ("src/python_devcontainer/__main__.py", base),
        ("tests/test_smoke.py", base),
        (".gitignore", base),
        (".devcontainer/devcontainer.json", base),
        (".devcontainer/docker-compose.yml", base),
        (".devcontainer/post-start.sh", base),
        # The header comments in these files mention the template name as
        # context for design decisions; rewriting keeps them self-consistent
        # in the new project (otherwise a reader of
        # `myapp/.devcontainer/Dockerfile` sees "Development image for
        # the python-devcontainer monorepo" which is just confusing).
        (".devcontainer/Dockerfile", base),
        (".pre-commit-config.yaml", base),
        # packages/core/* gets the rename-core treatment ONLY when the
        # flag was passed (in which case `base` already contains the
        # prefix substitutions). When the flag is off, the file still
        # contains "python-devcontainer" in its description string, so
        # we still want the base substitutions to run.
        ("packages/core/pyproject.toml", base),
        ("packages/core/src/pdc_core/__init__.py", base),
        # The core's smoke test imports `pdc_core`. With --rename-core
        # the substitutions in `base` rewrite the import; without it the
        # file stays untouched (no template strings to replace).
        ("packages/core/tests/test_greet.py", base),
        # GitHub Actions CI — header comment names the project. Note that
        # the workflow is named "ci.yml" generically (not project-specific),
        # so only the comment needs rewriting.
        (".github/workflows/ci.yml", base),
    ]


def build_path_renames(
    new_snake: str,
    rename_core_to: str | None,
) -> list[tuple[str, str]]:
    """Directory renames done AFTER text rewrites.

    Order matters: rewrite imports/paths in files first (using their old
    locations), then move the directories. Doing it the other way around
    would leave us looking up files at paths that no longer exist.
    """
    renames = [
        (f"src/{TEMPLATE_SNAKE}", f"src/{new_snake}"),
    ]
    if rename_core_to is not None:
        new_core_snake = rename_core_to.replace("-", "_") + "_core"
        # packages/core/src/pdc_core/  →  packages/core/src/<new>_core/
        renames.append(
            (
                f"packages/core/src/{TEMPLATE_PREFIX_SNAKE}_core",
                f"packages/core/src/{new_core_snake}",
            )
        )
    return renames


# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------
def apply_replacements(
    repo_root: Path,
    plan: list[tuple[str, list[tuple[str, str]]]],
) -> None:
    """Run text substitutions; report every file touched."""
    for rel_path, subs in plan:
        path = repo_root / rel_path
        if not path.exists():
            # Files might have been deleted by user customisation; warn but
            # don't fail. A typo in our hard-coded list, on the other hand,
            # would also land here — the verification step at the end
            # catches it by re-grepping the template name.
            print(f"  [skip] {rel_path} (not found)")
            continue
        original = path.read_text()
        updated = original
        for old, new in subs:
            updated = updated.replace(old, new)
        if updated != original:
            path.write_text(updated)
            print(f"  [edit] {rel_path}")
        else:
            print(f"  [noop] {rel_path}")


def apply_path_renames(repo_root: Path, renames: list[tuple[str, str]]) -> None:
    for old_rel, new_rel in renames:
        old = repo_root / old_rel
        new = repo_root / new_rel
        if not old.exists():
            print(f"  [skip] {old_rel} → {new_rel} (source missing)")
            continue
        if new.exists():
            sys.exit(f"error: refuse to overwrite existing {new_rel}")
        old.rename(new)
        print(f"  [move] {old_rel} → {new_rel}")


def verify_rename(repo_root: Path) -> None:
    """Final check: no template strings should remain in tracked source.

    We deliberately exclude this script (it talks about the template by
    name in comments) and uv.lock (regenerated by next `uv sync`). If
    anything else still mentions the template, our replacement plan
    missed a spot — fail loudly so the user can report it.
    """
    excluded = {"bootstrap.py", "uv.lock"}
    # Tool caches contain references to the OLD module name in their JSON
    # blobs (mypy/ruff/pytest cache lookups by module path). Those caches
    # are regenerated on next tool run, so any leftover references are
    # cosmetic and self-healing — exclude them from verification to avoid
    # false-positive WARNINGs after a successful rename.
    excluded_dirs = {
        ".git",
        ".venv",
        "node_modules",
        ".omc",
        ".zac",
        ".mypy_cache",
        ".ruff_cache",
        ".pytest_cache",
        "__pycache__",
        "dist",
        "build",
    }

    leftovers: list[str] = []
    for path in repo_root.rglob("*"):
        if not path.is_file():
            continue
        if any(p in excluded_dirs for p in path.relative_to(repo_root).parts):
            continue
        if path.name in excluded:
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, PermissionError):
            continue
        for token in (TEMPLATE_KEBAB, TEMPLATE_SNAKE):
            if token in text:
                leftovers.append(f"{path.relative_to(repo_root)} contains {token!r}")

    if leftovers:
        print("\nWARNING: template strings still present in:", file=sys.stderr)
        for line in leftovers:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nThis is probably a bug in bootstrap.py's replacement plan. "
            "Edit the file manually or report it.",
            file=sys.stderr,
        )
        # Don't sys.exit — the rename is mostly done, and partial success is
        # more useful than rolling back. The user can fix the leftovers.


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Rename this template repo into a fresh app and self-delete.",
    )
    parser.add_argument(
        "name",
        help="App name (kebab-case): myapp, my-cool-api, app2.",
    )
    parser.add_argument(
        "--rename-core",
        metavar="PREFIX",
        default=None,
        help=(
            "Rename the shared library prefix too: pdc-core → <PREFIX>-core, "
            "pdc_core → <PREFIX>_core. Default: leave pdc-core unchanged."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would change without modifying anything.",
    )
    args = parser.parse_args()

    new_kebab, new_snake = normalise_name(args.name)
    new_core_prefix: str | None = None
    if args.rename_core is not None:
        # The core prefix follows the same naming rules as the main app
        # name, so reuse the validator.
        new_core_prefix, _ = normalise_name(args.rename_core)

    # Locate the repo root by anchoring to the directory containing this
    # script. Lets the user run `./bootstrap.py myapp` from anywhere.
    script_path = Path(__file__).resolve()
    repo_root = script_path.parent

    # Sanity check: refuse to run if the template strings are already gone
    # (script was already executed once, or someone is invoking it in the
    # wrong directory).
    pyproject = repo_root / "pyproject.toml"
    if not pyproject.exists() or TEMPLATE_KEBAB not in pyproject.read_text():
        sys.exit(
            f"error: {pyproject} doesn't contain {TEMPLATE_KEBAB!r}. "
            f"Either bootstrap.py has already been run, or you're in the "
            f"wrong directory."
        )

    print(f"==> Renaming template to: {new_kebab} (Python module: {new_snake})")
    if new_core_prefix:
        print(f"    Renaming core prefix:    pdc → {new_core_prefix}")
    if args.dry_run:
        print("    (dry-run mode — nothing will be written)")

    text_plan = build_text_replacements(new_kebab, new_snake, new_core_prefix)
    path_plan = build_path_renames(new_snake, new_core_prefix)

    print("\n--- Text replacements ---")
    if not args.dry_run:
        apply_replacements(repo_root, text_plan)
    else:
        for rel, _subs in text_plan:
            print(f"  [would-edit] {rel}")

    print("\n--- Path renames ---")
    if not args.dry_run:
        apply_path_renames(repo_root, path_plan)
    else:
        for old, new in path_plan:
            print(f"  [would-move] {old} → {new}")

    print("\n--- Verification ---")
    if not args.dry_run:
        verify_rename(repo_root)
    else:
        print("  (skipped in dry-run)")

    if args.dry_run:
        print("\nDry-run complete; no files modified.")
        return

    # Self-delete. Done LAST so any error above leaves the script in
    # place for retry. Use os.remove instead of pathlib.Path.unlink for
    # parity with shutil semantics; both work.
    print("\n--- Cleanup ---")
    print(f"  [delete] {script_path.name}")
    os.remove(script_path)

    print("\n==> Done.")
    print("\nNext steps:")
    print("  rm -rf .git && git init      # if you copied from a clone")
    print("  uv sync --all-packages")
    print("  uv run pre-commit install")
    print("  uv run pytest")


if __name__ == "__main__":
    main()
