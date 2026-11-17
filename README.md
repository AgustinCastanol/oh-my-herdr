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
| `--with-extras` | Also install the curated community plugins in [Extras](#extras), each pinned to a reviewed commit |
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

This unlinks oh-my-herdr plugins, uninstalls the extras it installed, restores your previous config byte for byte (or removes the generated config if you had none), and deletes the `~/.local/share/oh-my-herdr` clone it created. Files it did not create are never deleted. Your `~/.config/oh-my-herdr/` and herdr stay.

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
| `sidebar` | Agent sidebar values that plugins and tools report: the pane's git branch (`$git`, from the `git-status` plugin) next to the agent, how long the agent has waited for you (`$waiting`, from the `agent-inbox` plugin), a watched pane's test result (`$tests`, from the `test-watcher` plugin), and the `$summary` / `$summary2` rows Gentle Shell reports; each stays invisible until reported | nothing | On |
| `task-runner` | `prefix+ctrl+t` opens the task-runner plugin's popup | `jq` (the plugin) | On when jq is installed |
| `agent-handoff` | `prefix+f` opens the agent-handoff plugin's popup | `jq` (the plugin) | On when jq is installed |
| `agent-inbox` | `prefix+i` opens the agent-inbox plugin's popup of agents waiting for you | `jq` (the plugin) | On when jq is installed |
| `prompt-library` | `prefix+shift+f` opens the prompt library: send a saved prompt to an agent | `jq` (the agent-handoff plugin) | On when jq is installed |
| `test-watcher` | `prefix+ctrl+w` starts or stops watching the focused pane for failing tests; `prefix+ctrl+e` sends its failure to an agent | `jq` (the plugins) | On when jq is installed |
| `agent-race` | `prefix+ctrl+r` starts an agent race, `prefix+ctrl+d` compares it, `prefix+ctrl+x` cleans it up | `jq` and `git` (the plugin) | On when jq and git are installed |
| `workspace-explorer` | `prefix+ctrl+o` opens an oil.nvim-style directory browser that opens a herdr workspace at the directory you pick | `jq` (the plugin) | On when jq is installed |

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
| `prefix`, then `ctrl+t` | Project task popup (`task-runner` module) | `t` for tasks; herdr's `prefix+r` is resize mode and `prefix+t` is the scratch shell |
| `prefix`, then `f` | Send the selection or recent pane output to another agent (`agent-handoff` module) | `f` for forward; `prefix+h` is pane focus, and many terminals send `ctrl+h` as Backspace |
| `prefix`, then `i` | Agents waiting for you; pick one to focus it (`agent-inbox` module) | `i` for inbox |
| `prefix`, then `shift+f` | Send a saved prompt to an agent (`prompt-library` module) | The capital of `f`; `prefix+p` is the previous tab |
| `prefix`, then `ctrl+w` / `ctrl+e` | Watch the focused pane for failing tests, or stop; send its failure to an agent (`test-watcher` module) | `w` for watch, `e` for error; herdr's `prefix+w` and `prefix+e` are taken |
| `prefix`, then `ctrl+r` / `ctrl+d` / `ctrl+x` | Start an agent race; compare its agents; clean it up (`agent-race` module) | `r` for race, `d` for diff, `x` for remove; herdr's `prefix+r` is resize mode and `prefix+x` closes a pane |
| `prefix`, then `ctrl+o` | Browse directories and open a workspace at one (`workspace-explorer` module) | `o` for open (and oil); herdr's `prefix+o` is taken |
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

> **herdr plugins are not sandboxed.** A plugin runs commands with your user's permissions. oh-my-herdr links only its own plugins by default; community plugins are installed only with `--with-extras` (see [Extras](#extras)).

| Plugin | Adds | Requires |
|--------|------|----------|
| `git-status` | Each pane's git branch as `$git`, shown next to the agent name by the `sidebar` module; optionally a `*` for uncommitted changes | `git`, `jq` |
| `task-runner` | A popup listing the focused pane's project tasks; the chosen one runs in a new split below that pane | `jq`; `fzf` optional |
| `agent-handoff` | Sends the selection, or the focused pane's recent output, to another agent that is already running, after a preview and your confirmation; and the prompt library, which sends a saved prompt the same way | `jq`; `fzf` optional |
| `agent-inbox` | A popup of the agents waiting for you, longest wait first, that focuses the one you pick; and how long each has waited as `$waiting` in the sidebar | `jq`; `fzf` optional |
| `test-watcher` | Watches panes you choose for failing tests or builds: `$tests` in the sidebar, a notification when one starts failing, and a shortcut to send the failure to an agent | `jq`; `fzf` optional |
| `agent-race` | Gives one task to 2 to 4 agents at once, each in its own git worktree from the same commit; compares what each changed; removes the worktrees and branches | `jq`, `git`; `fzf` optional |
| `workspace-explorer` | An oil.nvim-style directory browser whose only action is opening a herdr workspace at a directory, or focusing the one already there | `jq`; `fzf` optional |

**git-status details.** herdr sends no event when a pane changes directory, so the plugin refreshes when herdr starts, when a pane is created, and when a pane gets focus. Each value expires after 10 minutes unless refreshed, so a stale branch disappears instead of staying wrong. To refresh every pane now, run the plugin's "Refresh git status" action (`herdr plugin action invoke oh-my-herdr.git-status.refresh`). herdr's Spaces panel already shows each workspace's branch; this plugin adds the branch of each agent's own pane, which helps when agents work in different directories or worktrees. Problems (for example `jq` missing) are written to herdr's plugin log (`herdr plugin log list --plugin oh-my-herdr.git-status`) and never interrupt herdr.

**git-status safety.** The plugin runs git in whatever directory a pane is in, including repositories you have not reviewed. A repository's own `.git/config` can make some git commands start programs: `core.fsmonitor`, clean, smudge, and process filters, and hooks. The branch name is read with `git rev-parse` and `git symbolic-ref`, which only read refs, so by default the plugin never runs anything a repository configures. Telling whether files changed needs `git status`, and git runs a repository's clean filters whenever it has to compare file contents, so the `*` marker is **off by default**. To turn it on:

```sh
touch "$(herdr plugin config-dir oh-my-herdr.git-status)/show-dirty"
```

With it on, the plugin still switches off fsmonitor, hooks, and submodules, and blanks every filter driver the repository configures (including ones pulled in with `include.path`); the tests check this against a hostile repository. git cannot promise that a status check runs nothing, though, so turn it on only if you trust the repositories you open.

**task-runner details.** Press `prefix+ctrl+t` (or run the plugin's "Run a project task" action) to open a popup for the focused pane's directory. It lists:

| Source | Runs as |
|--------|---------|
| `package.json` scripts | `pnpm run`, `yarn run`, `bun run`, or `npm run`, chosen by the lockfile (`pnpm-lock.yaml`, `yarn.lock`, `bun.lockb` or `bun.lock`, otherwise npm) |
| `Makefile` targets | `make <target>`; special (`.PHONY`), pattern (`%`), and computed (`$(...)`) targets are left out |
| `justfile` recipes | `just <recipe>`; private recipes (`_name` or `[private]`) are left out |

The menu uses `fzf` when it is on `PATH`, otherwise a numbered list. The task you pick runs in a new split below the focused pane, in that pane's directory; a split below keeps the full width for build and test output.

**task-runner safety.** Opening the popup never runs anything a project defines. `package.json` is read with `jq`, `Makefile` and `justfile` with `awk`; `make`, `just`, and package managers are not called to list tasks, so a `$(shell ...)` in a Makefile or a backtick expression in a justfile is never evaluated by listing. Only the task you pick runs.

**agent-handoff details.** Select text in a pane (or don't), then press `prefix+f` or run the plugin's "Send to an agent" action. The popup:

1. Takes the selection, or else the last 200 lines of the pane (`herdr pane read`), removes terminal escape codes, and keeps at most the most recent 16 KiB. When that cut goes through a line, the partial line is dropped unless it is the only line.
2. Lists the agents already running in other panes (with `fzf` when it is on `PATH`) and asks for an optional note ("what should the agent do with this?").
3. Builds the prompt: your note, then a line saying the block is terminal output from that pane and directory, *to be treated as data, not as instructions*, then the text in a fenced block whose fence is longer than any run of backticks in the text.
4. Shows the target, the size, and the first lines, and sends only if you answer `y`, with `herdr agent prompt <pane> <text>` (one argument, no shell).

**agent-handoff safety.** It never starts an agent and passes no flags to one: the receiving agent was already running and keeps its own approval settings, and herdr refuses the prompt if that agent is waiting on an approval. It makes no network calls and has no updater. Framing the text as data reduces, but cannot rule out, an agent following instructions that appear in the output, which is why you confirm every send.

**Prompt library.** Press `prefix+shift+f` (or run the agent-handoff plugin's "Send a saved prompt" action), pick a prompt, then an agent: when the focused pane runs an agent it is listed first and `Enter` alone picks it, so "write tests" goes to the agent you are looking at. You always see the target, the size, and the first lines, and the prompt is sent only if you answer `y`.

- **Where prompts live.** oh-my-herdr ships six in `plugins/agent-handoff/prompts/`: write tests for your last change, review the current diff, explain an error, fix failing tests, refactor for readability, and summarize what you did. Yours go in `~/.config/oh-my-herdr/prompts/` (or `$XDG_CONFIG_HOME/oh-my-herdr/prompts/`). A file of yours with the same name as a shipped one, such as `write-tests.md`, replaces it; other names add prompts.
- **Format.** A prompt is a Markdown file ending in `.md`. Its title in the list is its first `# ` heading, or else the file name. The file is sent as written, heading included; nothing in it is run or expanded except two placeholders.
- **Placeholders.** `{{context}}` becomes the selection, or else the recent output of the focused pane, framed as data exactly like agent-handoff sends it (escape codes removed, at most the last 16 KiB, in a fence the text cannot close). `{{cwd}}` becomes that pane's directory. A prompt without `{{context}}` is sent without any pane output.

To add one:

```sh
mkdir -p ~/.config/oh-my-herdr/prompts
printf '# Check the logs\n\nFind the first error in the output below.\n\n{{context}}\n' \
  > ~/.config/oh-my-herdr/prompts/check-logs.md
```

**agent-inbox details.** An agent waits for you while herdr reports it as **blocked** (it shows an approval or a question) or **done** (it finished while you were looking at another workspace or tab; herdr turns it idle once you focus it). An agent that finishes in front of you becomes idle, not done, so it is not listed. Press `prefix+i` or run the plugin's "Open the agent inbox" action. The popup lists blocked agents first, then done ones, each longest wait first, with the agent, its workspace/tab, the last part of its directory, and how long it has waited (for example `waiting 14m`). Pick one (with `fzf` when it is on `PATH`, otherwise by number) to focus it. With nobody waiting, it says "No agents are waiting for you."

While an agent waits, the plugin also reports `$waiting` for its pane, for example `blocked since 14:32` or `done since 14:05`; the `sidebar` module shows it on its own row under the agent, and the row disappears when the agent works again, is focused after finishing, quits, or its pane closes. The time is fixed text, so nothing has to tick. herdr's events say neither the previous state nor when it changed, so on every agent status change, focus change, and pane exit the plugin compares `herdr agent list` with what it recorded in its state directory. When herdr starts, waits are counted from that moment.

**agent-inbox safety.** It reads agent state and runs `herdr agent focus` for the agent you pick. It never starts an agent, never sends one a prompt or keys, and makes no network calls.

**Test watcher.** Press `prefix+ctrl+w` in a pane where you run tests or builds (or run the test-watcher plugin's "Watch this pane for failing tests, or stop" action); press it again to stop. While a pane is watched:

- **Sidebar.** `$tests` shows `watching`, then `✗ failing since 14:32` once a run fails, and `✓ passing` once a later run passes; the `sidebar` module shows it on its own row. A passing result stays visible (rather than disappearing) so you can tell a watched, passing pane from one nobody watches. The row goes away when watching stops.
- **Notification.** When a watched pane starts failing, herdr shows a "Tests failing" notification naming the pane. Whether it appears, and with which sound, follows your herdr notification settings. A failure that was already on screen when you started watching is marked without a notification.
- **Sending the failure to an agent.** Press `prefix+ctrl+e` in that pane: agent-handoff's prompt popup opens on the "Fix the failing tests below" prompt with the pane's recent output attached, you pick the agent, and as always you see a preview and confirm before anything is sent.

What it detects is a heuristic. A watcher reads the last 60 lines of its pane every 2 to 6 seconds (more often right after output changed) and the last line that matches a failure or success pattern decides. The default patterns cover jest, vitest, pytest, `go test`, `cargo test`, mocha, rspec, `tsc`, rustc, `make`, `npm`, and lines starting with `Error:`, `FAIL`, or `PASS`. Counts of zero (`0 failed`, `3 examples, 0 failures`) are not failures, but a program that prints `Error:` or `2 errors` for another reason will be taken for a failure. To change the patterns, create a `patterns` file in the plugin config directory:

```sh
cat > "$(herdr plugin config-dir oh-my-herdr.test-watcher)/patterns" <<'EOF'
# One pattern per line: fail, pass, or ignore, then a POSIX extended
# regular expression matched against one line of output.
fail ^BUILD FAILED
pass ^BUILD SUCCESSFUL
ignore ^Error: expected in this project
EOF
```

`fail` lines replace all the default failure patterns and `pass` lines all the default success patterns; a file without `fail` (or `pass`) lines keeps those defaults. `ignore` lines are added: matching lines are skipped. To check a pattern, pipe sample output to `sh test-watcher.sh classify` with `HERDR_PLUGIN_CONFIG_DIR` set to that directory, in the plugin directory; it prints `fail`, `pass`, or nothing.

At most 8 panes are watched at once; the 9th is refused with a notification. A watcher stops when its pane exits or closes, when watching is toggled off, and when herdr starts; it never runs anything in the pane. Problems a watcher meets are written to `watchers/<pane>.log` in the plugin state directory.

**test-watcher safety.** It only reads pane output, reports the `$tests` token, and shows notifications. It never sends anything to an agent itself: the send shortcut opens agent-handoff's popup, where you choose and confirm. No network calls.

**Agent race.** Press `prefix+ctrl+r` in a pane inside a git repository (or run the agent-race plugin's "Start an agent race" action):

1. Type the task (one line), or press Enter to pick a saved prompt from the prompt library. Prompts that attach pane output (`{{context}}`) are not offered; `{{cwd}}` becomes each agent's own worktree.
2. Pick 2 to 4 agents among the kinds herdr can start (`herdr agent start --kind`) whose command is on `PATH` (with `fzf -m` when it is installed, otherwise by numbers).
3. Read the summary (task, repository, base commit, and each agent's branch and worktree) and answer `y`. Nothing is created or sent before that.

For each agent the plugin then creates a worktree on a new branch `race/<race>-<agent>` from the current commit, in `~/.herdr/worktrees/<repository>/race-<race>-<agent>` (herdr's default worktree directory), opens it as its own herdr workspace, and starts the agent there with `herdr agent start`. Each agent gets the task as soon as it is ready. If an agent stops at a startup prompt (for example asking whether to trust the new folder), answer it in that agent's pane and the task follows, for up to 10 minutes. A failure for one agent is reported and does not stop the others. At most 3 races exist at a time; clean one up to start another.

`prefix+ctrl+d` compares a race: for each agent, its state, whether it got the task, and `git diff --stat` against the base commit plus untracked files. Type an agent's number to open its full diff in a new pane below the focused one. If the community reviewer plugin `persiyanov.reviewr` is installed, the popup says so; it never runs it.

`prefix+ctrl+x` cleans a race up: it lists each worktree as clean, with changes, or with ignored files (such as `.env.local` or `node_modules`) and asks you to type the race name. Clean worktrees are removed and their workspaces closed (which ends their agents). Worktrees with changes or ignored files are removed only if you then type `discard`, since those files are lost with the worktree. Race branches that are merged are deleted; branches with commits that are not merged are deleted only if you type `delete`. The base branch is never touched. Cleanup acts only on what the race created: a line of the race record that names any other worktree (a different path, a path with `..`, or a symlink where the race's worktree would be), branch, or label is reported and left alone, and a workspace is closed only when its id and its label are the ones the race recorded. Compare also refuses a record whose base is not a full commit id.

**agent-race safety.** Agents start with `herdr agent start <name> --kind <kind> --pane <pane> --timeout <ms>`, which are herdr's own options, and no arguments for the agent, so each keeps its own approval settings; the plugin never passes an approval-bypass flag, and the tests check every agent call for one. The repository is found with `git rev-parse` only. herdr's own `worktree create` runs the repository's hooks and fsmonitor, so the plugin creates worktrees with `git worktree add` with hooks and fsmonitor turned off, then opens them in herdr. Diffs, status checks, and removals also run with hooks, fsmonitor, external diff tools, and textconv turned off. Checkout and clean filters (such as Git LFS) still run, as with any git command in your own repository. No network calls.

**Workspace explorer.** Press `prefix+ctrl+o` (or run the workspace-explorer plugin's "Explore directories and open a workspace" action). It starts at the focused pane's directory (or your home directory) and lists it like oil.nvim: `../` first, then directories with a trailing `/`, then files. Symlinks are marked `[symlink]`, and directories containing `.git` are marked `[project]`. Hidden entries are off until you toggle them; a directory it cannot read is reported and you stay where you were.

| With `fzf` | Without `fzf` (numbered menu) | Does |
|------------|-------------------------------|------|
| `Enter` on a directory | its number | Goes into it (`../` goes up, and stops at `/`) |
| `ctrl-o` | `o` or `o N` | Opens a workspace at the highlighted directory (`o N`: at entry N), or at the current directory when `../` or a file is highlighted (`o` alone) |
| `ctrl-t` | `h` | Shows or hides hidden entries |
| `Esc` | `q` | Closes |

Opening looks for a workspace that is already at that directory (a worktree workspace there, or one with a pane in that directory, comparing real paths) and focuses it; otherwise it runs `herdr workspace create --cwd <dir> --label <name> --focus`, labeling it `<parent>/<name>` when another workspace already uses the name. That is all it changes: it never creates, renames, edits, or deletes a file, and it lists directories with shell globs and file tests only, so no program (not even Git) runs in a directory you browse.

## Extras

`install.sh --with-extras` also installs these community plugins, each from a commit that was reviewed. Without the flag, none of them is installed. An extra whose requirements are not on `PATH` is skipped with a message, `--dry-run` lists what would be installed and skipped, and `--uninstall` uninstalls the extras it installed.

| Plugin | What it adds | Requires | Pinned commit |
|--------|--------------|----------|---------------|
| `persiyanov/herdr-reviewr` | Review the agent's diff in a pane and send line comments back to the agent. Optional `gh`, `glab`, or `az` add pull request views | `curl`, and `sha256sum` or `shasum` | `aede179` (tag v0.52.1) |
| `plannotator/herdr-annotate/lite` | Comment on text in a pane and send the comment to the agent | `pbcopy`, `wl-copy`, or `xclip` | `a9973b4` |
| `devashish2203/herdr-worktrunk` | Open worktrunk (`wt`) worktrees as herdr tabs or workspaces | `wt`, `fzf` | `f9df9ba` |
| `kryptamine/herdr-auto-title` | Name tabs and panes from their directory, branch, and the agent's task | nothing | `954b35d` (tag v0.21.0) |

The full 40-character commits, and the format for adding one, are in [extras.txt](extras.txt), the single source of the pins. To update an extra after reviewing a newer commit:

1. Change its ref in `extras.txt`.
2. Change its short commit in the table above (a test checks the table against `extras.txt`).
3. Run `make extras-hash` and write the value to `tests/fixtures/extras-reviewed.sha256`. The tests compare that file with `extras.txt`, so no pin changes without this deliberate step.
4. Run `make test`.

**Security notes**

- Extras are third-party code. Like any herdr plugin they are not sandboxed and run with your user's permissions.
- Pinning fixes the plugin's repository at one commit, including any script that downloads a binary. It does not fix the binary a release serves. Where a plugin downloads a release binary, the pin is a release-tag commit when one exists: reviewr (v0.52.1) and auto-title (v0.21.0) download binaries with provenance attestations. annotate's binary has no provenance attestation. worktrunk has no build step.
- reviewr opens a pane on its own when a worktree is created or opened (`worktree.created`, `worktree.opened`).
- auto-title runs in the background and reads agent transcripts on your machine to name tabs. To turn transcript reading off, set `HERDR_AUTO_TITLE_TRANSCRIPT=false` in the environment herdr starts from.

**Reviewed and not included:** `sanirudh17/herdr-agent-handoff`. It starts the receiving agent with its approval prompts bypassed, and its updater does not keep the pinned commit. oh-my-herdr ships its own minimal [agent-handoff](#plugins-plugins) plugin instead.

## Roadmap

- [x] `install.sh`: one command that installs herdr if missing, backs up your config, composes base and modules, and can `--dry-run` and `--uninstall`
- [x] Plugins: `git-status`, `task-runner`, `agent-handoff` (with a prompt library), `agent-inbox`, `test-watcher`, `agent-race`, `workspace-explorer` (herdr's `prefix+?` help serves as the cheatsheet)
- [x] Curated community plugins, pinned and opt-in (`--with-extras`)

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
