# paru-claude-review

Lets an LLM (Claude, or a local model via Ollama) review AUR build files (PKGBUILD, `.install`, patches) before paru asks
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
- `claude` (Claude Code CLI), logged in — for the default backend
- `ollama` + `ollama-cuda`, `curl`, `jq` — for the local backend
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

Set via environment or in `~/.config/aur-ai-review/config` (plain `KEY=value` lines,
not sourced; environment wins):

| Variable | Default | Meaning |
|---|---|---|
| `PARU_REVIEW_BACKEND` | `claude` | `claude` or `ollama` |
| `PARU_REVIEW_MAXBYTES` | `100000` | Max bytes per file / diff sent to the model |
| `PARU_CLAUDE_MODEL` | Claude Code default | Model passed to `claude --model` |
| `PARU_OLLAMA_MODEL` | `qwen2.5:14b-instruct-q4_K_M` | Ollama model |
| `PARU_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama server |
| `PARU_OLLAMA_CTX` | `32768` | Context window; Ollama's default (4096) truncates silently |

Example config:

```ini
PARU_REVIEW_BACKEND=ollama
PARU_OLLAMA_MODEL=qwen2.5:14b-instruct-q4_K_M
```

## Local backend (Ollama)

Requires `ollama` **and** `ollama-cuda` (Arch splits the GPU backend into its own package;
without it Ollama silently runs on CPU) plus `curl` and `jq`.

Run Ollama as a user service, using the models in `~/.ollama`:

```ini
# ~/.config/systemd/user/ollama.service
[Unit]
Description=Ollama (user)
After=network.target

[Service]
ExecStart=/usr/bin/ollama serve
Environment=OLLAMA_HOST=127.0.0.1:11434
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now ollama.service
journalctl --user -u ollama | grep 'inference compute'   # should list the GPU, not "cpu"
```

The local call has no tools at all (plain chat API, `temperature 0`). For reasoning models
`think: false` is sent; models that don't support it are retried without.

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

Results so far (2026-11-12, RTX 4070 for the local models):

| Package | Claude (Opus 5.5) | qwen2.5:14b | qwen3:8b |
|---|---|---|---|
| google-chrome | GREEN | GREEN | GREEN |
| miniconda3 | GREEN | GREEN | YELLOW |
| teamviewer | GREEN | YELLOW | YELLOW |
| anydesk-bin | GREEN | YELLOW | YELLOW |
| pipes.sh | GREEN | – | – |
| tidyclip (fake) | RED | YELLOW | RED |
| fastgrep-bin (fake) | RED | RED | RED |

All models catch the malicious update and ignore the injection comment. Local models raise
more false YELLOWs (remote-access services); treat their YELLOW as "maybe", their RED as real.
Borderline packages can flip between GREEN and YELLOW across runs; RED and the quoted lines
are the reliable signal. Local runs take 1–25 s on the GPU.
