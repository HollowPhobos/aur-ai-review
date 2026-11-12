#!/usr/bin/env bash
# Runs aur-ai-review over a set of real, popular (presumed clean) AUR packages
# plus the fake YELLOW/RED packages, and prints one verdict per package.
# Nothing is built or installed: real packages are only cloned from aur.archlinux.org.
#
#   tests/benchmark.sh <workdir> [backend] [model]
#   tests/benchmark.sh /tmp/aur-bench ollama gemma4:12b
#   tests/benchmark.sh /tmp/aur-bench claude
#
# Expected: GREEN for the clean list, YELLOW or RED for tidyclip, RED for fastgrep-bin.

set -u

here="$(cd "$(dirname "$0")" && pwd)"
reviewer="$here/../aur-ai-review"
work="${1:?usage: $0 <workdir> [backend] [model]}"
backend="${2:-claude}"
model="${3:-}"

# Popular AUR packages covering: plain scripts, -bin repacks, vendor installers,
# services/daemons, remote-access tools, source builds
clean=(
    pipes.sh pfetch yay
    google-chrome brave-bin visual-studio-code-bin spotify slack-desktop zoom
    teamviewer anydesk-bin nordvpn-bin miniconda3
)

mkdir -p "$work/clean"
work="$(cd "$work" && pwd)"

for pkg in "${clean[@]}"; do
    if [[ ! -d "$work/clean/$pkg" ]]; then
        git clone -q "https://aur.archlinux.org/$pkg.git" "$work/clean/$pkg" 2>/dev/null \
            || echo "could not fetch $pkg" >&2
    fi
done
if [[ ! -d "$work/fake/red" ]]; then
    "$here/make-fake-packages.sh" "$work/fake" >/dev/null
fi

export PARU_REVIEW_BACKEND="$backend"
if [[ -n "$model" ]]; then
    if [[ "$backend" == ollama ]]; then
        export PARU_OLLAMA_MODEL="$model"
    else
        export PARU_CLAUDE_MODEL="$model"
    fi
fi

run() {
    local label="$1" dir="$2" expect="$3" verdict
    verdict="$("$reviewer" "$dir" </dev/null 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -m1 -oE 'VERDICT: [A-Z]+' | cut -d' ' -f2)"
    printf '%-24s %-8s (expected %s)\n' "$label" "${verdict:-ERROR}" "$expect"
}

echo "backend=$backend model=${model:-default}"
for pkg in "${clean[@]}"; do
    [[ -d "$work/clean/$pkg" ]] && run "$pkg" "$work/clean/$pkg" GREEN
done
run "tidyclip (fake)" "$work/fake/yellow" "YELLOW/RED"
run "fastgrep-bin (fake)" "$work/fake/red" RED
