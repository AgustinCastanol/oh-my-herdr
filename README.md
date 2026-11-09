# oh-my-herdr

An opinionated, extensible setup for [herdr](https://herdr.dev), the terminal multiplexer for AI coding agents: a clean base config, opt-in modules, and a one-command installer that can be undone.

> **Status: work in progress, not yet published.** Until the GitHub repository is public, the `curl` one-liner below will not work; clone the repository and run `sh install.sh` instead. Targets herdr 0.9.0 or newer; tested with 0.9.5.

This is for the herdr **TUI** (`herdr` in your terminal), not the Herdr desktop app.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh
```

Expected result: `==> oh-my-herdr is installed.` herdr picks up the new config right away if it is running, or the next time it starts.

Preview first, without changing anything:

```sh
curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh -s -- --dry-run
```

Choose modules:

```sh
curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh -s -- --modules git,scratch
```

Run the same command again at any time to update. It keeps the modules you chose last time unless you pass `--modules`.

### Options

| Option | Effect |
|--------|--------|
| `--modules LIST` | Modules to enable: a comma-separated list, `all`, or `none` |
| `--dry-run` | Print every step and change nothing |
| `--uninstall` | Undo the install (see [Uninstall](#uninstall)) |
| `-y`, `--yes` | Skip the confirmation prompt; required for `--uninstall` through a pipe |
| `-h`, `--help` | Show usage |

### What the installer does

1. Checks for Linux or macOS and `git`.
2. Uses your herdr if it is 0.9.0 or newer. If herdr is missing, installs it with `brew install herdr`, or with herdr's own install script when Homebrew is not available. If it is older, stops and tells you how to upgrade.
3. Clones this repository, or updates the clone with `git pull --ff-only`.
4. Builds your herdr config from the base config, the chosen modules, and your `local.toml`, and checks it with `herdr config check`. If herdr rejects it, your current config is left untouched.
5. Backs up your existing config once, then replaces it.
6. Reloads the config in a running herdr server.

### What it touches

| Path | What happens |
|------|--------------|
| `~/.config/herdr/config.toml` (or `$HERDR_CONFIG_PATH`) | Replaced by a generated file that starts with `# Managed by oh-my-herdr.` Do not edit it: it is regenerated on every install. |
| `~/.config/herdr/config.toml.pre-oh-my-herdr` | Your previous config, saved the first time only. It is never overwritten; if it already exists next to an unmanaged config, the installer stops and asks you to move one of them. |
| `~/.local/share/oh-my-herdr` (or `$OMH_DIR`) | The cloned repository and an `.install-state` file used by `--uninstall`. |
| `~/.config/oh-my-herdr/local.toml` | Your own settings. Never written by the installer; appended to the generated config when it exists. |

herdr itself is never uninstalled.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh -s -- --uninstall --yes
```

This unlinks oh-my-herdr plugins, restores your previous config byte for byte (or removes the generated config if you had none), and deletes `~/.local/share/oh-my-herdr`. Your `local.toml` and herdr stay.

Without `--yes`, uninstall asks for confirmation, and refuses when it cannot ask because stdin is not a terminal (as with `curl | sh`).

herdr unlinks plugins only while it is running. If it is not, uninstall prints the `herdr plugin unlink <id>` command to run later.

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

| Module | Adds | Requires | Default |
|--------|------|----------|---------|
| `git` | `prefix+y` opens lazygit in a popup | [lazygit](https://github.com/jesseduffield/lazygit) | On when lazygit is installed |
| `scratch` | `prefix+t` opens a throwaway shell in a popup | a POSIX shell | On |
| `quiet` | Mutes agent state-change sounds | nothing | Off |

The default prefix is `ctrl+b`. How modules combine, what `local.toml` may contain, and how to write a module: [config/modules/README.md](config/modules/README.md).

### Plugins

There are no plugins yet. When they arrive, the installer links every plugin in `plugins/` with `herdr plugin link`.

> **herdr plugins are not sandboxed.** A plugin runs commands with your user's permissions. oh-my-herdr links only its own plugins by default; community plugins will be opt-in.

## Roadmap

- [x] `install.sh`: one command that installs herdr if missing, backs up your config, composes base and modules, and can `--dry-run` and `--uninstall`
- [ ] Plugins: `git-status`, `cheatsheet`, `task-runner`, `agent-handoff`
- [ ] Curated community plugins, pinned and opt-in (`--with-extras`)

## Development

| Tool | Used for |
|------|----------|
| [bats](https://github.com/bats-core/bats-core) | Tests in `tests/` |
| [shellcheck](https://www.shellcheck.net) | Linting `install.sh`, test helpers, stubs, and bats files |
| python3 3.11+ | Offline TOML and config-key checks (`tomllib`) |
| herdr (optional) | Real `herdr config check` tests; skipped when missing |

```sh
make check                                       # make lint + make test
INSTALL_SHELL=/bin/dash bats tests/install.bats  # run install.sh under a strict POSIX shell
```

Install from your working tree, without cloning:

```sh
OMH_SOURCE="$PWD" sh install.sh --dry-run
```

Tests replace herdr, brew, curl, git, and lazygit with stubs from `tests/stubs/`. The few tests that run a real herdr use a throwaway `HOME` and config path, so they never read or write your `~/.config/herdr` and never talk to a running herdr server.

## License

[MIT](LICENSE). The herdr config reference in `tests/fixtures/` is vendored from herdr under Apache-2.0; see [tests/fixtures/README.md](tests/fixtures/README.md).
