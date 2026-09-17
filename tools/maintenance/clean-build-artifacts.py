#!/usr/bin/env python3
"""Preview obsolete local app backups; --trash moves them reversibly to Trash.

Build products, models, node_modules and meeting evidence are never selected.
The current app and two newest rollback bundles are always retained.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import uuid


def candidates(root: Path, running: str):
    backups = sorted(
        (p for p in (root / "apps/macos/.build/app").glob("MeetingAgent-before-*.app") if p.is_dir() and not p.is_symlink()),
        key=lambda p: p.stat().st_mtime, reverse=True,
    )
    return [p for p in backups[2:] if str(p.resolve()) + "/" not in running]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trash", action="store_true", help="Move selected backups to macOS Trash")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    running = subprocess.check_output(["ps", "-ww", "-axo", "comm="], text=True)
    selected = candidates(root, running)
    for path in selected:
        size = sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())
        print(f'{"Trash" if args.trash else "Preview"}: {size / 1024 / 1024:.1f} MiB {path.relative_to(root)}')
        if args.trash:
            # Recheck immediately before mutation, including processes started since selection.
            current = subprocess.check_output(["ps", "-ww", "-axo", "comm="], text=True)
            if str(path.resolve()) + "/" in current:
                raise RuntimeError("A selected backup was started; retained it")
            destination = Path.home() / ".Trash" / f"{path.stem}-{uuid.uuid4().hex[:8]}.app"
            destination.parent.mkdir(exist_ok=True)
            shutil.move(str(path), str(destination))
    if not selected:
        print("No obsolete backups eligible for cleanup.")
    if not args.trash:
        print("Dry run. Use --trash to move the listed backups; empty Trash manually to reclaim disk space.")


if __name__ == "__main__":
    main()
