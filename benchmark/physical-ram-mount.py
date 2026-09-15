#!/usr/bin/env python3
"""Read-only diagnostics for a dedicated physical-RAM benchmark mount."""
import argparse
import json
import os
from pathlib import Path
import re


SCHEMA = "native-physical-ram-mount-v1"
OCTAL_ESCAPE = re.compile(r"\\([0-7]{3})")
DELETED_SUFFIX = " (deleted)"


def _decode(value):
    return OCTAL_ESCAPE.sub(lambda match: chr(int(match.group(1), 8)), value)


def _path_in_root(value, root):
    if not value or not value.startswith("/"):
        return False
    if value.endswith(DELETED_SUFFIX):
        value = value[:-len(DELETED_SUFFIX)]
    try:
        path = Path(value)
        return path == root or root in path.parents
    except (OSError, ValueError):
        return False


def _mounts(root, mountinfo):
    records = []
    for line in mountinfo.read_text(errors="replace").splitlines():
        fields = line.split()
        try:
            separator = fields.index("-")
            mountpoint = Path(_decode(fields[4]))
            if mountpoint != root and root not in mountpoint.parents:
                continue
            records.append({
                "mount_id": int(fields[0]),
                "parent_id": int(fields[1]),
                "device": fields[2],
                "root": _decode(fields[3]),
                "mountpoint": str(mountpoint),
                "filesystem": fields[separator + 1],
                "source": _decode(fields[separator + 2]),
                "options": sorted(set(fields[5].split(",")) |
                                  set(fields[separator + 3].split(","))),
            })
        except (IndexError, ValueError) as error:
            raise ValueError("malformed /proc mountinfo record") from error
    return records


def _identity(proc):
    text = (proc / "stat").read_text(errors="replace")
    tail = text[text.rfind(")") + 2:].split()
    if len(tail) < 20 or tail[0] == "Z":
        return None
    return {"pid": int(proc.name), "start_ticks": tail[19],
            "name": (proc / "comm").read_text(errors="replace").strip()[:128]}


def _target(link):
    try:
        return os.readlink(link)
    except FileNotFoundError:
        return None


def _process_references(proc, root):
    references = []
    seen = set()

    def add(kind, target, descriptor=None):
        if not _path_in_root(target, root):
            return
        key = (kind, descriptor, target)
        if key in seen:
            return
        seen.add(key)
        record = {"type": kind, "target": target,
                  "deleted": target.endswith(DELETED_SUFFIX)}
        if descriptor is not None:
            record["descriptor"] = descriptor
        references.append(record)

    for kind in ("cwd", "root", "exe"):
        target = _target(proc / kind)
        if target is not None:
            add(kind, target)

    fd = proc / "fd"
    try:
        entries = list(fd.iterdir())
    except FileNotFoundError:
        entries = []
    for entry in entries:
        target = _target(entry)
        if target is not None:
            add("fd", target, entry.name)

    try:
        maps = (proc / "maps").read_text(errors="replace")
    except FileNotFoundError:
        maps = ""
    for line in maps.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) == 6:
            add("mmap", fields[5])
    return references


def inspect_mount(root, proc_root=Path("/proc"), mountinfo=None):
    root = Path(root)
    if not root.is_absolute() or root == Path("/"):
        raise ValueError("RAM root must be an absolute non-root path")
    if root.is_symlink() or root.resolve(strict=False) != root:
        raise ValueError("RAM root and its parents must not be symlinks")
    mountinfo = Path(mountinfo) if mountinfo is not None else Path(proc_root) / "self/mountinfo"
    errors = []
    try:
        mounts = _mounts(root, mountinfo)
    except (OSError, ValueError) as error:
        mounts = []
        errors.append("mountinfo: " + str(error))
    exact = [record for record in mounts if record["mountpoint"] == str(root)]
    nested = [record for record in mounts if record["mountpoint"] != str(root)]
    holders = []
    try:
        processes = sorted((entry for entry in Path(proc_root).iterdir()
                            if entry.name.isdigit()), key=lambda entry: int(entry.name))
    except OSError as error:
        processes = []
        errors.append("process scan: " + str(error))
    for proc in processes:
        if int(proc.name) == os.getpid() and Path(proc_root) == Path("/proc"):
            continue
        try:
            before = _identity(proc)
            if before is None:
                continue
            references = _process_references(proc, root)
            after = _identity(proc)
            if after is None or after["start_ticks"] != before["start_ticks"]:
                continue
            if references:
                holders.append({**before, "references": references})
        except FileNotFoundError:
            continue
        except PermissionError as error:
            errors.append(f"pid {proc.name}: {error}")
        except (OSError, ValueError, IndexError) as error:
            errors.append(f"pid {proc.name}: {type(error).__name__}: {error}")
    stacked = exact[:-1]
    mounted = bool(exact)
    return {
        "schema": SCHEMA,
        "root": str(root),
        "mounted": mounted,
        "root_mount": exact[-1] if exact else None,
        "stacked_root_mounts": stacked,
        "nested_mounts": nested,
        "holders": holders,
        "errors": errors,
        "diagnostics_complete": not errors,
        "unmount_ready": not stacked and not nested and not holders and not errors,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default="/mnt/mylocalton-ram")
    args = parser.parse_args(argv)
    try:
        report = inspect_mount(args.root)
        status = 0 if not report["errors"] else 2
    except (OSError, ValueError) as error:
        report = {"schema": SCHEMA, "root": args.root, "mounted": None,
                  "root_mount": None, "stacked_root_mounts": [],
                  "nested_mounts": [], "holders": [], "errors": [str(error)],
                  "diagnostics_complete": False, "unmount_ready": False}
        status = 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return status


if __name__ == "__main__":
    raise SystemExit(main())
