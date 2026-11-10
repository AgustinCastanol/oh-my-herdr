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

Run the same command again at any time to update. It keeps the theme and modules you chose last time unless you pass `--theme` or `--modules`.

### Options

| Option | Effect |
|--------|--------|
| `--theme NAME` | Theme from `config/themes/`: `gentle` (default) or `tokyo-night` |
| `--modules LIST` | Modules to enable: a comma-separated list, `all`, or `none` |
| `--dry-run` | Print every step and change nothing |
| `--uninstall` | Undo the install (see [Uninstall](#uninstall)) |
| `-y`, `--yes` | Skip the confirmation prompt; required for `--uninstall` through a pipe |
| `-h`, `--help` | Show usage |

### What the installer does

1. Checks for Linux or macOS and `git`.
2. Clones this repository, or updates the clone with `git pull --ff-only`, and checks your `--theme` and `--modules` choices.
3. Uses your herdr if it is 0.9.0 or newer. If herdr is missing, installs it with `brew install herdr`, or by downloading herdr's own install script and running it once the download succeeded. If herdr is older, stops and tells you how to upgrade.
4. Builds your herdr config from the base config, the theme, the keybindings, the chosen modules, and your own files (see [Customizing](#customizing)), and checks it with `herdr config check`. If herdr rejects it, your current config is left untouched.
5. Backs up your existing config once, then replaces it.
6. Reloads the config in a running herdr server.

### What it touches

| Path | What happens |
|------|--------------|
| `~/.config/herdr/config.toml` (or `$HERDR_CONFIG_PATH`) | Replaced by a generated file that starts with `# Managed by oh-my-herdr.` Do not edit it: it is regenerated on every install. |
| `~/.config/herdr/config.toml.pre-oh-my-herdr` | Your previous config, saved the first time only. It is never overwritten; if it already exists next to an unmanaged config, the installer stops and asks you to move one of them. |
| `~/.local/share/oh-my-herdr` (or `$OMH_DIR`) | The cloned repository, an `.install-state` file used by `--uninstall`, and an `.oh-my-herdr` marker. The installer refuses an existing, non-empty directory it did not create. |
| `~/.config/oh-my-herdr/` | Your own files: `local.toml` and copies of shipped layers (see [Customizing](#customizing)). Read, never written by the installer. |

herdr itself is never uninstalled.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh -s -- --uninstall --yes
```

This unlinks oh-my-herdr plugins, restores your previous config byte for byte (or removes the generated config if you had none), and deletes the `~/.local/share/oh-my-herdr` clone it created. Files it did not create are never deleted. Your `~/.config/oh-my-herdr/` and herdr stay.

Without `--yes`, uninstall asks for confirmation, and refuses when it cannot ask because stdin is not a terminal (as with `curl | sh`).

herdr unlinks plugins only while it is running. If it is not, uninstall prints the `herdr plugin unlink <id>` command to run later.

## What is included

### Base config: `config/base.toml`

Stays close to herdr's defaults. Keybindings live in their own layer, `config/keys.toml`; see [Keybindings](#keybindings).

| Setting | Effect |
|---------|--------|
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
| `engram` | `prefix+m` opens the Engram memory browser (`engram tui`) in a popup | [engram](https://github.com/Gentleman-Programming/engram) | On when engram is installed |
| `sidebar` | Agent sidebar values that plugins and tools report: the pane's git branch (`$git`, from the `git-status` plugin) next to the agent, and the `$summary` / `$summary2` rows Gentle Shell reports; each stays invisible until reported | nothing | On |

How the base config, a theme, the keybindings, and modules combine, and how to write a module: [config/modules/README.md](config/modules/README.md).

### Themes: `config/themes/`

Exactly one theme is installed. Pick it with `--theme NAME`; later runs keep it.

| Theme | Looks like |
|-------|------------|
| `gentle` (default) | herdr's `one-dark` with the Gentle palette: near-black panels, muted teal accent, green, rose, and sand |
| `tokyo-night` | herdr's built-in `tokyo-night`, unchanged |

To add a theme, create `config/themes/<name>.toml` with an `# Adds:` and `# Requires:` header, a `[theme]` table, and optional `[theme.custom]` colors, then run `make test`. Details: [config/modules/README.md](config/modules/README.md#themes).

The Gentle palette is adapted from the herdr config in [Gentleman.Dots](https://github.com/Gentleman-Programming/Gentleman.Dots) (Apache-2.0).

## Customizing

Put your own files in `~/.config/oh-my-herdr/` (or `$XDG_CONFIG_HOME/oh-my-herdr/`), then run the installer again. It checks the result with `herdr config check` before replacing your config, so a broken file stops the install and leaves your current config untouched.

| Your file | Effect |
|-----------|--------|
| `base.toml`, `keys.toml` | Used **instead of** the shipped file |
| `themes/NAME.toml`, `modules/NAME.toml` | Used instead of the shipped file with that name; a new name can be selected with `--theme NAME` or `--modules NAME` |
| `local.toml` | Appended last, for settings that add to the config |

The installer prints every layer it takes from your directory, also with `--dry-run`.

Example: change the prefix back to `ctrl+b`.

```sh
mkdir -p ~/.config/oh-my-herdr
cp ~/.local/share/oh-my-herdr/config/keys.toml ~/.config/oh-my-herdr/keys.toml
# edit prefix = "ctrl+b" in the copy, then:
curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh
```

An override replaces the **whole** file; there is no per-key merge. That keeps the installer a plain POSIX shell script with no TOML parser. The tradeoff: your copy does not pick up later changes to the shipped file, so compare it after an update. For settings that only **add** to the config, such as a new `[[keys.command]]` popup or `[ui.toast.herdr]`, use `local.toml` instead: it can add tables, but cannot redefine one that a layer already defines.

## Keybindings

`config/keys.toml` changes herdr's prefix from `ctrl+b` to `ctrl+a` and adds agent navigation; to change these, see [Customizing](#customizing). Everything else keeps herdr's defaults; press `prefix+?` in herdr to see all of them.

| Keys | Action | Why |
|------|--------|-----|
| `ctrl+a` | Prefix | Matches tmux, screen, and Zellij muscle memory |
| `ctrl+a`, `ctrl+a` | Send a literal `ctrl+a` to the pane | Pressing the prefix again leaves prefix mode and passes the key through, for example to jump to the start of a shell line |
| `prefix`, then `alt+k` / `alt+j` | Previous / next agent in the agent panel | Mirrors `prefix+k` / `prefix+j` pane focus without clashing with herdr's `prefix+shift+k` / `prefix+shift+j` pane swaps |
| `prefix`, then `ctrl+1` … `ctrl+9` | Focus agent 1-9 | `alt+number` is often taken by window managers |
| `prefix`, then `y` | lazygit popup (`git` module) | |
| `prefix`, then `t` | Scratch shell popup (`scratch` module) | |
| `prefix`, then `m` | Engram memory popup (`engram` module) | |
| `prefix`, then `?` | herdr's keybinding help | Built into herdr |

herdr's help panel (`prefix+?`) is the cheatsheet: besides herdr's own bindings, it lists every module popup under "custom" with its description, so oh-my-herdr ships no separate one. Every shipped popup has a description; the tests check it.

Some terminals do not pass `alt+letter` or `ctrl+number` through. On macOS, `alt` chords need your terminal's "Option as Alt" (or Meta) setting. If one of these does nothing, check your terminal's keyboard settings.

### Agent integrations

After an install, the installer reads `herdr integration status` (local files only, no server needed) and suggests `herdr integration install <name>` for agents on your `PATH` whose integration is missing or outdated. Integrations let herdr resume an agent's session after a restart. The installer never installs one itself.

## Gentle Shell inside herdr

[Gentle Shell](https://github.com/Gentleman-Programming/gentle-ai) reports its state to herdr as a custom agent and publishes two sidebar values, `$summary` and `$summary2`, with `herdr pane report-metadata`. It never edits your herdr config, so those values appear only if your sidebar layout has rows for them. The `sidebar` module (on by default) adds them under herdr's default agent rows. herdr hides tokens nobody reported and rows without a value, so the rows cost nothing when Gentle Shell is not running.

Known issue: when Gentle Shell is installed in **Separate** mode, its launcher rebuilds the environment without `HERDR_ENV`, `HERDR_SOCKET_PATH`, and `HERDR_PANE_ID`. Even when started from a herdr pane, its herdr reporter then never activates: herdr shows the pane without an agent, and the summary rows stay empty. This is an upstream bug ([gentle-ai#6033](https://github.com/Gentleman-Programming/gentle-ai/issues/6033), open); oh-my-herdr cannot work around it.

### Plugins: `plugins/`

The installer links every plugin in `plugins/` with `herdr plugin link`. A plugin whose `# Requires:` tools are missing is skipped with a message, and `--dry-run` lists what it would link and skip.

> **herdr plugins are not sandboxed.** A plugin runs commands with your user's permissions. oh-my-herdr links only its own plugins by default; community plugins will be opt-in.

| Plugin | Adds | Requires |
|--------|------|----------|
| `git-status` | Each pane's git branch as `$git`, shown next to the agent name by the `sidebar` module; optionally a `*` for uncommitted changes | `git`, `jq` |

**git-status details.** herdr sends no event when a pane changes directory, so the plugin refreshes when herdr starts, when a pane is created, and when a pane gets focus. Each value expires after 10 minutes unless refreshed, so a stale branch disappears instead of staying wrong. To refresh every pane now, run the plugin's "Refresh git status" action (`herdr plugin action invoke oh-my-herdr.git-status.refresh`). herdr's Spaces panel already shows each workspace's branch; this plugin adds the branch of each agent's own pane, which helps when agents work in different directories or worktrees. Problems (for example `jq` missing) are written to herdr's plugin log (`herdr plugin log list --plugin oh-my-herdr.git-status`) and never interrupt herdr.

**git-status safety.** The plugin runs git in whatever directory a pane is in, including repositories you have not reviewed. A repository's own `.git/config` can make some git commands start programs: `core.fsmonitor`, clean, smudge, and process filters, and hooks. The branch name is read with `git rev-parse` and `git symbolic-ref`, which only read refs, so by default the plugin never runs anything a repository configures. Telling whether files changed needs `git status`, and git runs a repository's clean filters whenever it has to compare file contents, so the `*` marker is **off by default**. To turn it on:

```sh
touch "$(herdr plugin config-dir oh-my-herdr.git-status)/show-dirty"
```

With it on, the plugin still switches off fsmonitor, hooks, and submodules, and blanks every filter driver the repository configures (including ones pulled in with `include.path`); the tests check this against a hostile repository. git cannot promise that a status check runs nothing, though, so turn it on only if you trust the repositories you open.

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
