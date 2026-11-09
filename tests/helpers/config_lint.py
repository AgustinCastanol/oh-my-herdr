"""Offline checks for oh-my-herdr config files.

Usage:
  config_lint.py compose FILE...                 print FILE... joined the way the installer joins them
  config_lint.py parse FILE...                   check that the joined files are valid TOML
  config_lint.py check-keys REFERENCE FILE...    check keys and values against herdr's config reference
  config_lint.py check-module FILE               check a module's header and first table

Exit status: 0 when clean, 1 when issues were found (one per line on stdout), 2 on usage errors.
"""

import json
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    sys.stderr.write("config_lint: Python 3.11+ is required (tomllib)\n")
    sys.exit(2)


# The reference JSON does not describe the fields of these array entries.
# Source: https://herdr.dev/tui/docs/configuration/ (custom command keybindings,
# UI and sidebar sections), herdr v0.9.5.
COMMAND_FIELDS = {"key", "type", "command", "description", "width", "height"}
COMMAND_REQUIRED = {"key", "type", "command"}
COMMAND_TYPES = {"popup", "pane", "shell", "plugin_action"}
TAB_BAR_RIGHT_FIELDS = {"type", "format", "text", "command", "interval_seconds", "timeout_seconds"}

HEADER_LINE = re.compile(r"^\s*\[")


def read_joined(paths):
    """Join files in order, separated by a newline, like the installer does."""
    parts = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            parts.append(handle.read())
    return "\n".join(parts)


def load_toml(paths):
    return tomllib.loads(read_joined(paths))


def load_reference(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return {entry["key"]: entry for section in data["sections"] for entry in section["keys"]}


def default_bindings(reference):
    """Every default keybinding string in the reference, with 1..9 ranges expanded."""
    bindings = set()
    for name, entry in reference.items():
        if not name.startswith("keys.") or name.startswith("keys.indexed."):
            continue
        default = entry["default"]
        if not default.startswith('"'):
            continue  # "unset" or a non-string default
        value = json.loads(default).strip().lower()
        if value.endswith("1..9"):
            stem = value[: -len("1..9")]
            bindings.update(f"{stem}{digit}" for digit in range(1, 10))
        elif value:
            bindings.add(value)
    return bindings


def check_value(name, value, entry, issues):
    if entry["type"] == "enum" and isinstance(value, str) and value not in entry.get("values", []):
        issues.append(f"{name}: invalid value {value!r}; expected one of {entry['values']}")
    if name == "ui.tab_bar_right":
        check_tab_bar_right(value, entry, issues)


def check_tab_bar_right(value, entry, issues):
    if not isinstance(value, list):
        issues.append("ui.tab_bar_right: expected an array of tables")
        return
    for index, item in enumerate(value):
        where = f"ui.tab_bar_right[{index}]"
        if not isinstance(item, dict):
            issues.append(f"{where}: expected a table")
            continue
        if item.get("type") not in entry.get("values", []):
            issues.append(f"{where}.type: invalid value {item.get('type')!r}; expected one of {entry['values']}")
        for field in sorted(set(item) - TAB_BAR_RIGHT_FIELDS):
            issues.append(f"{where}: unknown field {field!r}")


def check_commands(value, reference, issues):
    if not isinstance(value, list):
        issues.append("keys.command: expected [[keys.command]] array of tables")
        return
    taken = default_bindings(reference)
    seen = {}
    for index, item in enumerate(value):
        where = f"keys.command[{index}]"
        for field in sorted(set(item) - COMMAND_FIELDS):
            issues.append(f"{where}: unknown field {field!r}")
        for field in sorted(COMMAND_REQUIRED - set(item)):
            issues.append(f"{where}: missing required field {field!r}")
        if "type" in item and item["type"] not in COMMAND_TYPES:
            issues.append(f"{where}.type: invalid value {item['type']!r}; expected one of {sorted(COMMAND_TYPES)}")
        key = str(item.get("key", "")).strip().lower()
        if key in taken:
            issues.append(f"{where}.key: {key!r} shadows a herdr default keybinding")
        if key and key in seen:
            issues.append(f"{where}.key: {key!r} is already used by keys.command[{seen[key]}]")
        seen.setdefault(key, index)


def walk(node, path, reference, issues):
    for name, value in node.items():
        full = f"{path}.{name}" if path else name
        if full in reference:
            check_value(full, value, reference[full], issues)
        elif full == "keys.command":
            check_commands(value, reference, issues)
        elif isinstance(value, dict) and any(key.startswith(full + ".") for key in reference):
            walk(value, full, reference, issues)
        else:
            issues.append(f"{full}: unknown config key")


def check_module(path):
    """A module must document itself and must start with a table header.

    A key = value line before the first header would land inside whatever
    table the previous file ended with once the files are joined.
    """
    issues = []
    header = []
    first_statement = None
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("#"):
                if first_statement is None:
                    header.append(stripped)
                continue
            first_statement = stripped
            break
    for label in ("# Adds:", "# Requires:"):
        if not any(line.startswith(label) for line in header):
            issues.append(f"{path}: header comment is missing a {label!r} line")
    if first_statement is None:
        issues.append(f"{path}: module defines no tables")
    elif not HEADER_LINE.match(first_statement):
        issues.append(f"{path}: first statement must be a table header, found {first_statement!r}")
    return issues


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    command, args = argv[1], argv[2:]
    try:
        if command == "compose" and args:
            sys.stdout.write(read_joined(args))
            return 0
        if command == "parse" and args:
            load_toml(args)
            return 0
        if command == "check-keys" and len(args) >= 2:
            issues = []
            walk(load_toml(args[1:]), "", load_reference(args[0]), issues)
        elif command == "check-module" and len(args) == 1:
            issues = check_module(args[0])
        else:
            sys.stderr.write(__doc__)
            return 2
    except tomllib.TOMLDecodeError as error:
        print(f"TOML parse error: {error}")
        return 1
    except OSError as error:
        print(f"{error.filename}: {error.strerror}")
        return 1
    for issue in issues:
        print(issue)
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
