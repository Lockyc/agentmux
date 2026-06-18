You are installing or updating **agentmux** — a configurable tmux agent launcher for Claude Code and other AI CLIs.

GitHub: `https://github.com/lockyc/agentmux`

---

## Steps

### 1. Detect repo location

Check whether the current working directory is the agentmux repo:

```bash
[ -f install.sh ] && [ -f VERSION ] && [ -f scripts/agentmux-config.sh ] && echo "IN_REPO" || echo "NOT_IN_REPO"
```

**If in repo:** set `REPO_DIR` to the current working directory.

**If not in repo:** clone from GitHub into a temp directory:

```bash
CLONE_DIR=$(mktemp -d) && git clone --depth 1 https://github.com/lockyc/agentmux "$CLONE_DIR/agentmux" 2>&1 && echo "$CLONE_DIR/agentmux"
```

Set `REPO_DIR` to the cloned path. If the clone fails, report the error and stop.

### 2. Check dependencies

```bash
which toml2json >/dev/null 2>&1 && echo "toml2json: ok" || echo "toml2json: MISSING"
which jq        >/dev/null 2>&1 && echo "jq: ok"        || echo "jq: MISSING"
```

If either is missing, offer to install via Homebrew:

```bash
brew install go-toml   # provides toml2json
brew install jq
```

If Homebrew is unavailable and deps are missing, warn the user and continue — `install.sh` will succeed but agentmux won't function until deps are present.

### 3. Check current install state

Detect what is already wired so question defaults are smart:

```bash
if [ ! -e ~/.agentmux ]; then echo "state:fresh";
elif [ -d ~/.agentmux/.git ]; then echo "state:clone";
elif [ -L ~/.agentmux/scripts ] || [ -L ~/.agentmux/bin ] || [ -L ~/.agentmux/shell ] || [ -L ~/.agentmux/tmux ]; then echo "state:dev-symlink";
else echo "state:old-copy"; fi
grep -qs "agentmux" ~/.zshrc                  && echo "zshrc:wired"  || echo "zshrc:missing"
grep -qs "agentmux" ~/.bashrc                 && echo "bashrc:wired" || echo "bashrc:missing"
grep -qs "agentmux" ~/.config/fish/config.fish && echo "fish:wired"  || echo "fish:missing"
grep -qs "agentmux" ~/.tmux.conf              && echo "tmux:wired"   || echo "tmux:missing"
grep -qs "agentmux" ~/.claude/settings.json && echo "hooks:wired" || echo "hooks:missing"
```

Also probe for running local LLM endpoints:

```bash
curl -sf --max-time 2 http://localhost:1234/v1/models  -o /dev/null && echo "lmstudio:running" || echo "lmstudio:not_running"
curl -sf --max-time 2 http://localhost:11434/v1/models -o /dev/null && echo "ollama:running"   || echo "ollama:not_running"
```

### 3.5 Migrate an old copy-install (if detected)

The install model is now a git clone at `~/.agentmux`. A pre-clone copy-install
(real files, no `.git`, not symlinks) must be migrated — `install.sh` refuses to
touch it automatically, so handle it here.

Detect:

```bash
if [ -d ~/.agentmux ] && [ ! -d ~/.agentmux/.git ] && [ ! -L ~/.agentmux/scripts ] && [ ! -L ~/.agentmux/bin ] && [ ! -L ~/.agentmux/shell ] && [ ! -L ~/.agentmux/tmux ]; then echo "OLD_COPY"; else echo "OK"; fi
```

If `OLD_COPY`, use AskUserQuestion to confirm migration, explaining: "Your
`~/.agentmux` is an older copy-install. Migrating moves it to a timestamped
backup, clones the current version in its place, and restores your `amux.toml`.
Proceed?"

On confirmation, back it up (the core install in step 4 will then clone fresh
because the path is gone):

```bash
TS=$(date +%Y%m%d-%H%M%S); mv ~/.agentmux ~/.agentmux.bak.$TS && echo "backed up to ~/.agentmux.bak.$TS"
```

Note the actual backup path from that output — reuse the same `~/.agentmux.bak.<timestamp>` literal in the restore step below; the `$TS` shell variable does not persist across separate command runs.

Remember `~/.agentmux.bak.$TS` — after step 4 clones, restore the user's config:

```bash
for f in amux.toml agents.toml; do [ -f ~/.agentmux.bak.$TS/$f ] && cp ~/.agentmux.bak.$TS/$f ~/.agentmux/amux.toml && echo "restored $f as amux.toml" && break; done
```

Tell the user the backup remains at `~/.agentmux.bak.$TS` and they can delete it
once they're satisfied the new install works.

If the user declines migration, stop — do not run the core install (it would
refuse anyway).

### 4. Run core install

`install.sh` now manages `~/.agentmux` as a git clone: it clones if the path is
absent (the case right after a 3.5 migration), `git pull`s an existing clone, and
leaves a dev/symlink install untouched. It does not depend on `$REPO_DIR`.

```bash
bash "$REPO_DIR/install.sh"
```

If a migration happened in step 3.5, restore the backed-up `amux.toml` now (see
the restore command there). If this fails, show the full output and stop.

### 5. Ask what to set up

Use AskUserQuestion with a **multi-select** question:

**"What should I set up for you?"**

Mark as "Recommended" those not already detected as wired. Also mark **AI summary status lines** as Recommended if either LLM endpoint was detected running in step 3.

- **Shell config** — wires the agentmux source line into your shell config: `~/.zshrc`/`~/.bashrc` (bash/zsh) and/or `~/.config/fish/config.fish` (fish)
- **tmux config** — appends `source-file ~/.agentmux/tmux/agentmux.conf` to `~/.tmux.conf`
- **Claude Code hooks** — wires tab-state emojis and AI summary triggers into `~/.claude/settings.json`
- **AI summary status lines** — configures the local LLM endpoint that powers the live `done / now / next` status bar

### 6. Wire shell config (if selected)

Wire every shell the user actually uses — determine targets from `$SHELL` and which config files exist. A user on fish may also keep a bash/zsh rc; wire each that applies.

**bash/zsh** — only if the user uses bash/zsh (`$SHELL` ends in `bash`/`zsh`, or a `~/.zshrc`/`~/.bashrc` already exists — do **not** create one for a fish-only user). Use `~/.zshrc` if it exists, otherwise `~/.bashrc`. If `source ~/.agentmux/shell/agentmux.sh` is not already present, append:

```
# agentmux
source ~/.agentmux/shell/agentmux.sh
```

**fish** — if `~/.config/fish/config.fish` exists or `$SHELL` ends in `fish`. If `agentmux.fish` is not already sourced there, append (note the `.fish` file, not `.sh`; the `test -f` guard keeps fish startup clean if agentmux is later removed):

```
# agentmux
test -f ~/.agentmux/shell/agentmux.fish; and source ~/.agentmux/shell/agentmux.fish
```

Report, per shell wired, whether the line was already present or newly added.

### 7. Wire tmux config (if selected)

Read `~/.tmux.conf` (create it if it doesn't exist). If `source-file ~/.agentmux/tmux/agentmux.conf` is not already present, append:

```
# agentmux
source-file ~/.agentmux/tmux/agentmux.conf
```

Report whether the line was already present or newly added.

### 8. Wire Claude Code hooks (if selected)

The six hooks to wire:

```
"SessionStart":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh start" }] }]
"UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }]
"PostToolUse":       [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }]
"Notification":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh notify" }] }]
"PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh permission --notify 'Claude is waiting for permission'" }] }]
"Stop":              [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh done --notify 'Claude has finished working'" }] }]
```

**Merge rules — never remove or overwrite hooks belonging to other tools:**

1. Read `~/.claude/settings.json` (treat as `{}` if the file does not exist).
2. For each of the six event names, check whether any entry in the current array already contains `agentmux` in its `command`. Skip that event if already wired.
3. Append our entry to each un-wired event array (create the array if the key is absent).
4. Write the merged result back with a single `jq` pipeline:

```bash
jq '.hooks.SessionStart += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh start"}]}]
  | .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh working"}]}]
  | .hooks.PostToolUse += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh working"}]}]
  | .hooks.Notification += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh notify"}]}]
  | .hooks.PermissionRequest += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh permission --notify '\''Claude is waiting for permission'\''"}]}]
  | .hooks.Stop += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh done --notify '\''Claude has finished working'\''"}]}]' \
  ~/.claude/settings.json > /tmp/settings-merged.json && mv /tmp/settings-merged.json ~/.claude/settings.json
```

Omit events that are already wired. If `~/.claude/settings.json` does not exist, seed with `echo '{"hooks":{}}' | jq ...`.

### 9. Configure AI summary status lines (if selected)

AI summaries require a local OpenAI-compatible endpoint — any `/v1/chat/completions` server works (LM Studio, Ollama, llama.cpp, etc.). The status bar shows a rolling `done / now / next` summary of the active Claude session, updated automatically on each tool use.

**9a. Ask which provider**

Use AskUserQuestion (single-select):

**"Which local LLM are you using for AI summaries?"**

Use the probe results from step 3 to add "(detected — running)" next to options that responded. Use the built-in Other escape hatch for custom URLs.

- **LM Studio** — endpoint: `http://localhost:1234/v1/chat/completions`
- **Ollama** — endpoint: `http://localhost:11434/v1/chat/completions`
- **Skip for now** — I'll configure this later in `~/.agentmux/amux.toml`

**9b. Ask for model name**

If a provider was selected (not Skip):

Use AskUserQuestion (single-select):

**"Which model do you want to use for summaries? (small, fast instruct models work best)"**

Options tailored to the provider (use the built-in Other escape hatch for unlisted models):
- For **LM Studio**: `qwen2.5-7b-instruct`, `qwen2.5-14b-instruct`, `mistral-7b-instruct`
- For **Ollama**: `qwen2.5:7b`, `qwen2.5:14b`, `llama3.1:8b`
- For **Custom**: `qwen2.5-14b-instruct`, `mistral-7b-instruct`, `llama3.1-8b-instruct`

**9c. Write config**

Read `~/.agentmux/amux.toml`. Update the `[llm]` section — replace `url` and `model` with the chosen values (keep `timeout = 20` unless a custom timeout was specified). Write the file back.

If the `[llm]` section is absent (unlikely — `install.sh` creates it from the example), append it.

### 10. Self-install this command

So `/agentmux:install` is available globally in future Claude Code sessions:

```bash
mkdir -p ~/.claude/commands/agentmux
```

Read `$REPO_DIR/.claude/commands/agentmux/install.md` and write it verbatim to `~/.claude/commands/agentmux/install.md`.

### 11. Summary

Print a summary in three sections:

Read `$REPO_DIR/VERSION` to get the installed version string.

**Installed**
- agentmux vX.X.X → `~/.agentmux/` ✓  (substitute actual version from VERSION file)
- List each wired item (shell config / tmux config / hooks / LLM) with its target file and status (wired / already present / skipped)

**Reload**
Only include commands that are actually relevant:
```bash
source ~/.zshrc                    # if zsh/bash config was wired
source ~/.config/fish/config.fish  # if fish config was wired (or start a new fish shell)
tmux source ~/.tmux.conf           # if tmux config was wired (or start a new tmux server)
```
Restart Claude Code if hooks were wired — hooks take effect on the next session start.

**Next steps**
- Edit `~/.agentmux/amux.toml` to define your agents — this is where you set names, colours, commands, key bindings, and optional `dirs` for directory-based agent selection (a bare `amux` auto-picks the agent whose `dirs` matches the current directory). Run `amux --colours` to preview the palette and copy a ready-made `colour = "name"` line; raw `colour_inactive`/`colour_active` still work as an override.
- Run `amux` to launch your first session
- If AI summaries were configured: the status bar populates automatically once Claude Code hooks are active and a session is running
- If AI summaries were skipped: configure later by setting `url` and `model` under `[llm]` in `~/.agentmux/amux.toml`
- The `--notify` flags in the `PermissionRequest` and `Stop` hooks trigger macOS desktop alerts via `osascript` — remove them from `~/.claude/settings.json` if unwanted
- Update agentmux any time with `amux --update` (it's a git clone now — a plain `git pull`).
- Side-terminal layout: `amux --frame [agent] [session]` opens a scratch terminal beside amux (nested tmux, no `~/.tmux.conf` changes). Set the left-pane width with `[frame] left = <percent>`, and optionally split the left column top/bottom with `[frame] left_vertical_split = <percent>` (top sub-pane height). Further `[frame]` toggles: `focus = "agent"|"terminal"` (start pane, default agent), `status_position = "bottom"|"top"` (the `[amux frame]` bar, default bottom), and `default = true` to make a bare `amux` open a frame (`amux --no-frame` opts out for one run). Any `[frame]` field can be overridden per-directory (and its subtree) with a `[frame.dirs."<path>"]` block — same matching as an agent's `dirs`, resolved per-field. See the README for the frame's prefix keys.
- Pin a project's **status-bar** colour (distinct from an agent's tab colour) with a per-directory `[amux.dirs."<path>"]` block: `colour = "<name>"`. This freezes that project's bar colour and removes it from the auto-assign pool, so no other project ever takes it — even when the pinned project is closed. Without a pin, a session's bar colour is a stable hash of its name, but two projects can collide and swap colours by launch order. Run `amux --colours` for the bar colour names.
- Enable a once-daily update check by setting `[update] check = true` in `~/.agentmux/amux.toml`.
