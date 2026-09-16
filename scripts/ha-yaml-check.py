#!/usr/bin/env python3
"""Lint Home Assistant YAML files without needing a running HA instance.

HA's config uses custom tags (!secret, !include, ...) that only resolve
inside HA itself. A plain PyYAML SafeLoader raises on every one of them, so
this subclass accepts them as opaque values instead of resolving them —
enough to catch a genuine syntax error, not enough to validate semantics.

Usage: ha-yaml-check.py FILE [FILE ...]
Exits non-zero and prints "file:line: message" for each file that fails to
parse.
"""
import sys

import yaml

HA_TAGS = (
    "!secret",
    "!include",
    "!include_dir_list",
    "!include_dir_named",
    "!include_dir_merge_list",
    "!include_dir_merge_named",
    "!env_var",
    "!input",
)


class HaSafeLoader(yaml.SafeLoader):
    pass


def _construct_opaque(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


HaSafeLoader.add_multi_constructor("!", _construct_opaque)


def check_file(path: str) -> bool:
    try:
        with open(path, encoding="utf8") as f:
            yaml.load(f, Loader=HaSafeLoader)
        return True
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        line = mark.line + 1 if mark else "?"
        message = getattr(e, "problem", None) or str(e)
        print(f"{path}:{line}: {message}", file=sys.stderr)
        return False


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: ha-yaml-check.py FILE [FILE ...]", file=sys.stderr)
        return 2
    ok = True
    for path in sys.argv[1:]:
        if not check_file(path):
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
