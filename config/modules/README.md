# Modules

Modules are small, opt-in additions to `config/base.toml` and the chosen theme from `config/themes/`. Each one adds a single feature, such as a keybinding for an external tool.

| Module | Adds | Requires | Installed by default |
|--------|------|----------|----------------------|
| `git.toml` | `prefix+y` opens lazygit in a popup | lazygit | Yes, when lazygit is on PATH |
| `scratch.toml` | `prefix+t` opens a throwaway shell in a popup | a POSIX shell | Yes |
| `quiet.toml` | Mutes agent state-change sounds | nothing | No |
| `engram.toml` | `prefix+m` opens `engram tui` in a popup | engram | Yes, when engram is on PATH |
| `sidebar.toml` | Agent sidebar values: `$git` (from the `git-status` plugin) next to the agent, plus rows for the `$summary` and `$summary2` values that tools like Gentle Shell report. The only module that may define `[ui.sidebar.agents]` | nothing | Yes |
| `task-runner.toml` | `prefix+ctrl+t` opens the task-runner plugin's popup (a `plugin_action` keybinding) | jq | Yes, when jq is on PATH |

Choose modules with `install.sh --modules git,quiet` (or `all`, or `none`). A later run without `--modules` keeps the modules chosen last time.

## How the config is combined

`install.sh` builds `config.toml` by joining these, in order, with a newline between them:

1. a two-line `# Managed by oh-my-herdr.` header, which marks the file as generated
2. `config/base.toml`
3. one theme from `config/themes/` (`--theme`, default `gentle`)
4. `config/keys.toml`
5. each enabled module, in the order given to `--modules` (file-name order for defaults and `all`)
6. `~/.config/oh-my-herdr/local.toml`, if it exists: your own settings

For steps 2 to 5, a file with the same path in `~/.config/oh-my-herdr/` (for example `keys.toml` or `modules/git.toml`) is used **instead of** the shipped one. Theme and module names that exist only there can be selected like shipped ones. See "Customizing" in the [README](../../README.md#customizing).

There is no merging. The result is plain concatenated TOML, so every module must be valid TOML **after** base, the theme, keys, and any other module. `herdr config check` validates the result before it replaces your config.

## Composition rule

Each layer owns the tables it defines:

| Layer | Owns |
|-------|------|
| `base.toml` | `[ui]`, `[ui.toast]` |
| a theme | `[theme]` and `[theme.custom]` (plus `[theme.custom.light]` / `[theme.custom.dark]` if it defines them) |
| `keys.toml` | `[keys]` |
| a module | whatever tables it defines, such as `[ui.sound]` in `quiet.toml` |

A module may add only:

- array-of-tables entries, such as `[[keys.command]]` (allowed even though `keys.toml` defines `[keys]`), or
- tables that neither base, a theme, nor `keys.toml` defines, such as `[ui.sound]`.

A module must never redefine a table that base, a theme, or `keys.toml` defines. Redefining one is a TOML error (duplicate table), and herdr would ignore the whole file and start with defaults. Two modules must not define the same table either.

`local.toml` follows the same rule. It comes last, so it may add tables nothing else defines, such as `[ui.toast.herdr]`, or more `[[keys.command]]` entries. It cannot change a setting that base, the theme, `keys.toml`, or an enabled module already sets, such as a keybinding in `[keys]` or a theme color, because TOML does not allow a table to be defined twice. To change those, put your own copy of that layer in `~/.config/oh-my-herdr/` instead.

## Writing a module

1. Start the file with a comment header that has an `# Adds:` line and a `# Requires:` line. When the module needs a tool, write it as `# Requires: <tool> on PATH ...`: the installer reads that form to skip the module by default when the tool is missing, and to warn when it is selected anyway. Otherwise write what it needs in plain words, or "nothing".
2. Make the first statement after the header a table header (`[...]` or `[[...]]`). A `key = value` line before any header would land inside the last table of the previous file.
3. For `[[keys.command]]`, pick a `key` that herdr does not already bind, counting both herdr's defaults (`herdr --default-config`) and the keys `keys.toml` sets in `[keys]`. Prefer plain `prefix+<letter>` keys: alt chords need "Option as Alt" on most macOS terminals.
4. To make the module a default, add its name to `DEFAULT_MODULES` in `install.sh`. Modules are opt-in otherwise.
5. Run `make test`.

The tests enforce these rules:

| Check | What it catches |
|-------|-----------------|
| `check-module` | Missing `Adds`/`Requires` header, or a bare key before the first table |
| Compose and parse | A redefined table, in base plus each theme plus each module, and plus all modules |
| `check-keys` | Keys or enum values missing from the vendored herdr config reference (see [tests/fixtures/README.md](../../tests/fixtures/README.md)), command keys that shadow a herdr keybinding (a default, or one set in `[keys]`) or another module |
| `herdr config check` | Anything herdr itself rejects, for every theme with every module (runs only when herdr is installed) |

## Themes

A theme is a file in `config/themes/` with the same header rules as a module (`# Adds:`, `# Requires:`, then a table). It must define `[theme]` and may define `[theme.custom]` color overrides; see `theme.*` in herdr's config reference. Run `make test` after adding one: the tests compose it with base and every module, and check it with herdr.
