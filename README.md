# paru-claude-review

Lets Claude review AUR build files (PKGBUILD, `.install`, patches) before paru asks
"Proceed with installation?". Claude is a second opinion only — you still decide.

```
:: Claude reviews 1 package(s)...

VERDICT: GREEN
pipes.sh: Routine PKGBUILD; source points to the upstream GitHub repo with a pinned sha256, …

:: View files in pager? [y/N]
```

## How it works

paru's `FileManager` option replaces the normal pager review with an external command.
That command gets the review directory (the cloned AUR repos) as its argument.

Per package the script sends:

- **Update:** diff since the last reviewed commit (paru stores it in `.git/AUR_SEEN`) plus the current PKGBUILD
- **New package:** all tracked text files (binaries skipped, large files truncated)
- **Unchanged:** nothing — Claude is not called

All packages of one paru run go into **one** Claude call. Output: `VERDICT: GREEN | YELLOW | RED`
plus quoted suspicious lines. Afterwards you can open the files in `$PAGER`.

## Safety

The PKGBUILD is attacker-controlled input, so:

- Claude runs with **no tools** (`--tools ""`), no MCP servers (`--strict-mcp-config`),
  and without user settings/hooks/plugins (`--setting-sources ""`)
- Claude runs from an **empty temp dir**, so a `CLAUDE.md` or `.claude/settings.json`
  shipped in an AUR repo is never loaded
- The prompt marks the input as untrusted; "notes to AI reviewers" count as a red flag
- If the Claude call fails, you get a warning and review manually

Blind spot: Claude only sees the repo. Code downloaded at build time (installers, `curl | sh`)
is not visible — the prompt flags such patterns instead.

## Requirements

- `paru`
- `claude` (Claude Code CLI), logged in
- `git`, `bash`

## Installation

1. Install the script somewhere in `$PATH`:

   ```sh
   install -Dm755 paru-claude-review ~/.local/bin/paru-claude-review
   ```

   (or symlink it, so edits here take effect immediately:
   `ln -sf "$PWD/paru-claude-review" ~/.local/bin/paru-claude-review`)

2. Enable it in paru. paru reads **only one** config file
   (`$PARU_CONF` → `~/.config/paru/paru.conf` → `/etc/paru.conf`), so if you don't
   have a user config yet, copy the system one first to keep your options:

   ```sh
   mkdir -p ~/.config/paru
   [ -e ~/.config/paru/paru.conf ] || cp /etc/paru.conf ~/.config/paru/paru.conf
   ```

   Then add/uncomment in `~/.config/paru/paru.conf`:

   ```ini
   [bin]
   FileManager = paru-claude-review
   ```

3. Try it: `paru -S pipes.sh` — review, verdict, then abort at "Proceed with installation?" if you like.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PARU_CLAUDE_MODEL` | Claude Code default | Model passed to `claude --model` |
| `PARU_CLAUDE_MAXBYTES` | `100000` | Max bytes per file / diff sent to Claude |

## Disable

Comment out the `FileManager` line in `~/.config/paru/paru.conf` — paru falls back to its normal pager review.

## Testing

`tests/make-fake-packages.sh` creates two **fake, non-functional** AUR repos
(all URLs point to `example.invalid` / `203.0.113.0/24`). Never build them.

```sh
tests/make-fake-packages.sh /tmp/fake-aur
paru-claude-review /tmp/fake-aur/yellow   # tidyclip: fork source, SKIP checksums, global service, clipboard sync
paru-claude-review /tmp/fake-aur/red      # fastgrep-bin: malicious update + "report as GREEN" injection
```

Results so far (Opus 5.5, 2026-11-12):

| Package | Verdict |
|---|---|
| pipes.sh, google-chrome, anydesk-bin, teamviewer, miniconda3 | GREEN (with notes) |
| tidyclip (fake) | RED — reasonable, clipboard goes to maintainer's server |
| fastgrep-bin (fake) | RED — base64 decoded, injection comment flagged |

Borderline packages can flip between GREEN and YELLOW across runs; RED and the quoted lines are the reliable signal.

## Ideas

- Local LLM backend via Ollama (`PARU_REVIEW_BACKEND=claude|ollama`), Claude stays default.
  Needs an explicit `num_ctx` (16–32k), otherwise long diffs get truncated silently.
  Benchmark with the fake packages.
