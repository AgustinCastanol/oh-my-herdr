# Test fixtures

Data the test suite reads. Do not edit vendored files by hand; replace them from upstream.

## herdr config reference (`herdr-<version>-config-reference.json`)

The machine-readable herdr config reference. `tests/config.bats` uses it to check that every key in `config/` exists in herdr and that enum values are valid, without needing herdr installed.

| Field | Value |
|-------|-------|
| Source | <https://raw.githubusercontent.com/herdrdev/herdr/v0.9.5/docs/next/website/src/data/config-reference.json> |
| Version | herdr v0.9.5 (git tag `v0.9.5`) |
| License | Apache-2.0, copyright the herdr authors (<https://github.com/herdrdev/herdr/blob/v0.9.5/LICENSE>) |
| SHA-256 | `86b27928b1ce20fe20b0a41dc524be9228de0d98ac43ed147064a814cdac35c7` |
| Changes | None. The file is vendored byte-for-byte. |

The reference does not list the fields of `[[keys.command]]` entries or of `ui.tab_bar_right` entries. `tests/helpers/config_lint.py` keeps those two small allowlists, taken from the herdr configuration docs: <https://herdr.dev/tui/docs/configuration/>.

## Where the pinned version lives

The file name is the single source of truth for tests. `find_herdr_reference` in `tests/helpers/common.bash` picks up the one `herdr-<version>-config-reference.json` in this directory and derives the version from its name. Tests fail if there is none or more than one.

The pinned version is the herdr release the tests check against. It is separate from the minimum supported herdr version (0.9.0), which `install.sh`, `config/base.toml`, and `README.md` state.

## git-status/

Plugin event and pane fixtures for `tests/git-status.bats`, shaped like the output of herdr 0.9.5: `pane-created.json` and `pane-focused.json` are the `HERDR_PLUGIN_EVENT_JSON` herdr passes to event hooks, and `pane-get.json` / `pane-list.json` are `herdr pane get` / `herdr pane list` responses. They were captured from an isolated herdr server; directories are replaced by `@CWD@` and `@CWD2@`, which the tests fill in.

## task-runner/

Small projects for `tests/task-runner.bats`, one per task source: `package.json` with each lockfile, a `Makefile` with special, pattern, computed, and variable lines that must not be listed, a `justfile` with settings, aliases, assignments, and private recipes, an empty project, and a hostile project whose files would run code if a tool evaluated them.

## Updating to a newer herdr

1. Download `config-reference.json` from the new tag into this directory as `herdr-<version>-config-reference.json`, and delete the old file.
2. Update the table above: source URL, version, and SHA-256 (`shasum -a 256 <file>`).
3. Update "tested with" in the top-level `README.md`.
4. Re-check `COMMAND_FIELDS`, `COMMAND_TYPES`, and `TAB_BAR_RIGHT_FIELDS` in `tests/helpers/config_lint.py` against the configuration docs for that release.
5. Run `make test`.
