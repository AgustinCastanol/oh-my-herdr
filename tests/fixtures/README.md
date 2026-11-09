# Test fixtures

Data the test suite reads. Do not edit vendored files by hand; replace them from upstream.

## herdr-0.9.5-config-reference.json

The machine-readable herdr config reference. `tests/config.bats` uses it to check that every key in `config/` exists in herdr and that enum values are valid, without needing herdr installed.

| Field | Value |
|-------|-------|
| Source | <https://raw.githubusercontent.com/herdrdev/herdr/v0.9.5/docs/next/website/src/data/config-reference.json> |
| Version | herdr v0.9.5 (git tag `v0.9.5`) |
| License | Apache-2.0, copyright the herdr authors (<https://github.com/herdrdev/herdr/blob/v0.9.5/LICENSE>) |
| SHA-256 | `86b27928b1ce20fe20b0a41dc524be9228de0d98ac43ed147064a814cdac35c7` |
| Changes | None. The file is vendored byte-for-byte. |

The reference does not list the fields of `[[keys.command]]` entries or of `ui.tab_bar_right` entries. `tests/helpers/config_lint.py` keeps those two small allowlists, taken from the herdr configuration docs: <https://herdr.dev/tui/docs/configuration/>.

## Updating to a newer herdr

1. Download the file from the new tag into this directory, named `herdr-<version>-config-reference.json`.
2. Point `HERDR_REFERENCE` in `tests/helpers/common.bash` at it and delete the old file.
3. Update the table above (URL, version, SHA-256 from `shasum -a 256 <file>`).
4. Run `make test`.
