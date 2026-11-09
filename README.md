# oh-my-herdr

An opinionated, extensible setup for [herdr](https://herdr.dev), the terminal multiplexer for AI coding agents: a clean base config, opt-in modules, and (soon) plugins and a one-command installer.

> **Status: work in progress.** There is no installer yet. Today the repo ships a base config and three modules you can try by hand. Targets herdr 0.9.0 or newer; tested with 0.9.5.

This is for the herdr **TUI** (`herdr` in your terminal), not the Herdr desktop app.

## What is included

### Base config: `config/base.toml`

Stays close to herdr's defaults and does not change any keybinding.

| Setting | Effect |
|---------|--------|
| `theme.name = "tokyo-night"` | Built-in dark theme |
| `ui.status_indicators = "symbols"` | Agent states use distinct glyphs, not color-only dots |
| `ui.show_agent_labels_on_pane_borders = true` | Split panes show which agent runs in them |
| `ui.tab_bar_right` | `ZOOM` marker while a pane is zoomed, plus a clock |
| `ui.toast.delivery = "herdr"` | In-app toast when a background agent finishes or needs input |
| `onboarding = false` | Skips the first-run flow, which would rewrite `config.toml` |

### Modules: `config/modules/`

Opt-in additions, appended after the base config.

| Module | Adds | Requires |
|--------|------|----------|
| `git.toml` | `prefix+y` opens lazygit in a popup | [lazygit](https://github.com/jesseduffield/lazygit) |
| `scratch.toml` | `prefix+t` opens a throwaway shell in a popup | a POSIX shell |
| `quiet.toml` | Mutes agent state-change sounds | nothing |

The default prefix is `ctrl+b`. How modules combine, and how to write one: [config/modules/README.md](config/modules/README.md).

## Try it by hand

Run these from the repository root.

1. Check the config. This only reads the file:

   ```sh
   HERDR_CONFIG_PATH="$PWD/config/base.toml" herdr config check
   ```

   Expected output: `config: ok`.

2. Back up your current config, if you have one:

   ```sh
   cp ~/.config/herdr/config.toml ~/.config/herdr/config.toml.bak
   ```

3. Write the base config, followed by any modules you want:

   ```sh
   cat config/base.toml config/modules/git.toml > ~/.config/herdr/config.toml
   ```

4. Apply it to the running herdr:

   ```sh
   herdr server reload-config
   ```

To undo, restore the backup and reload:

```sh
mv ~/.config/herdr/config.toml.bak ~/.config/herdr/config.toml
herdr server reload-config
```

## Roadmap

- [ ] `install.sh`: one command that installs herdr if missing, backs up your config, composes base and modules, and can `--dry-run` and `--uninstall`
- [ ] Plugins: `git-status`, `cheatsheet`, `task-runner`, `agent-handoff`
- [ ] Curated community plugins, pinned and opt-in (`--with-extras`)

## Development

| Tool | Used for |
|------|----------|
| [bats](https://github.com/bats-core/bats-core) | Tests in `tests/` |
| [shellcheck](https://www.shellcheck.net) | Linting shell and bats files |
| python3 3.11+ | Offline TOML and config-key checks (`tomllib`) |
| herdr (optional) | Real `herdr config check` tests; skipped when missing |

```sh
make check   # make lint + make test
```

Tests that run herdr use a throwaway `HOME` and config path. They never read or write your `~/.config/herdr` and never talk to a running herdr server.

## License

[MIT](LICENSE). The herdr config reference in `tests/fixtures/` is vendored from herdr under Apache-2.0; see [tests/fixtures/README.md](tests/fixtures/README.md).
