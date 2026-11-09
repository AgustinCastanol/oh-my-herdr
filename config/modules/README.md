# Modules

Modules are small, opt-in additions to `config/base.toml`. Each one adds a single feature, such as a keybinding for an external tool.

| Module | Adds | Requires |
|--------|------|----------|
| `git.toml` | `prefix+y` opens lazygit in a popup | lazygit |
| `scratch.toml` | `prefix+t` opens a throwaway shell in a popup | a POSIX shell |
| `quiet.toml` | Mutes agent state-change sounds | nothing |

## How modules are combined

The installer builds `config.toml` by joining files in this order, with a newline between them:

1. `config/base.toml`
2. each enabled module

There is no merging. The result is plain concatenated TOML, so every module must be valid TOML **after** base and after any other module.

## Composition rule

A module may add only:

- array-of-tables entries, such as `[[keys.command]]`, or
- tables that `base.toml` does not define, such as `[ui.sound]`.

A module must never redefine a table that base defines. Today those are `[theme]`, `[ui]`, and `[ui.toast]`. Redefining one is a TOML error (duplicate table), and herdr would ignore the whole file and start with defaults.

A table defined by one module is owned by that module. Two modules must not define the same table either.

## Writing a module

1. Start the file with a comment header that has an `# Adds:` line and a `# Requires:` line (external tools, or "nothing").
2. Make the first statement after the header a table header (`[...]` or `[[...]]`). A `key = value` line before any header would land inside the last table of the previous file.
3. For `[[keys.command]]`, pick a `key` that herdr does not already bind. Run `herdr --default-config` to see the defaults. Prefer plain `prefix+<letter>` keys: alt chords need "Option as Alt" on most macOS terminals.
4. Run `make test`.

The tests enforce these rules:

| Check | What it catches |
|-------|-----------------|
| `check-module` | Missing `Adds`/`Requires` header, or a bare key before the first table |
| Compose and parse | A redefined table, in base plus each module and base plus all modules |
| `check-keys` | Keys or enum values that herdr 0.9.5 does not know, command keys that shadow a herdr default or another module |
| `herdr config check` | Anything herdr itself rejects (runs only when herdr is installed) |
