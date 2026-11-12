#!/usr/bin/env bash
# Runs aur-ai-review over a set of real, popular (presumed clean) AUR packages
# plus the fake YELLOW/RED packages, and prints one verdict per package.
# Nothing is built or installed: real packages are only cloned from aur.archlinux.org.
#
#   tests/benchmark.sh <workdir> [backend] [model]
#   tests/benchmark.sh /tmp/aur-bench ollama gemma4:12b
#   tests/benchmark.sh /tmp/aur-bench claude sonnet
#
# Expected: GREEN for the clean list, YELLOW or RED for tidyclip, RED for fastgrep-bin.
#
# Reproducibility:
#   tests/packages.lock pins every package to an AUR commit, so all runs review the same
#   input. Missing entries are added on first run; delete a line (or the file) to re-pin.
# Results:
#   every run is stored in tests/results/<date>_<backend>_<model>/
#     meta.txt      date, backend, model, reviewer commit, prompt hash
#     summary.tsv   package, version, commit, expected, verdict, seconds
#     <package>.txt full review output

set -u

here="$(cd "$(dirname "$0")" && pwd)"
reviewer="$here/../aur-ai-review"
lock="$here/packages.lock"
work="${1:?usage: $0 <workdir> [backend] [model]}"
backend="${2:-claude}"
model="${3:-}"

# Popular AUR packages covering: plain scripts, -bin repacks, vendor installers,
# services/daemons, remote-access tools, source builds.
# yay comes first on purpose: a known-good package absorbs the cold start (Ollama model
# load, Claude CLI startup) the same way for every backend.
clean=(
    yay pipes.sh pfetch
    google-chrome brave-bin visual-studio-code-bin spotify slack-desktop zoom
    teamviewer anydesk-bin nordvpn-bin miniconda3
)

mkdir -p "$work/clean"
work="$(cd "$work" && pwd)"
touch "$lock"

# Fetch packages and check out the pinned commit (pin HEAD if not pinned yet)
for pkg in "${clean[@]}"; do
    dir="$work/clean/$pkg"
    if [[ ! -d "$dir" ]]; then
        git clone -q "https://aur.archlinux.org/$pkg.git" "$dir" 2>/dev/null \
            || { echo "could not fetch $pkg" >&2; continue; }
    fi
    pinned="$(awk -v p="$pkg" '$1 == p { print $2 }' "$lock")"
    if [[ -z "$pinned" ]]; then
        git -C "$dir" checkout -q origin/HEAD 2>/dev/null
        echo "$pkg $(git -C "$dir" rev-parse HEAD)" >>"$lock"
        echo "pinned $pkg" >&2
    elif ! git -C "$dir" checkout -q "$pinned" 2>/dev/null; then
        git -C "$dir" fetch -q origin && git -C "$dir" checkout -q "$pinned" \
            || echo "could not check out pinned commit for $pkg" >&2
    fi
done
sort -o "$lock" "$lock"

if [[ ! -d "$work/fake/red" ]]; then
    "$here/make-fake-packages.sh" "$work/fake" >/dev/null
fi

export PARU_REVIEW_BACKEND="$backend"
export PARU_REVIEW_NO_PAGER=1
if [[ -n "$model" ]]; then
    if [[ "$backend" == ollama ]]; then
        export PARU_OLLAMA_MODEL="$model"
    else
        export PARU_CLAUDE_MODEL="$model"
    fi
fi

# Result directory
model_label="${model:-default}"
if [[ "$backend" == ollama && -z "$model" ]]; then
    model_label="$(sed -n 's/^ollama_model="\${PARU_OLLAMA_MODEL:-\(.*\)}"$/\1/p' "$reviewer")"
fi
results="$here/results/$(date +%Y-%m-%d_%H%M)_${backend}_${model_label//[^A-Za-z0-9._-]/-}"
mkdir -p "$results"

reviewer_commit="$(git -C "$here/.." rev-parse --short HEAD 2>/dev/null)"
if [[ -n "$(git -C "$here/.." status --porcelain -- aur-ai-review 2>/dev/null)" ]]; then
    reviewer_commit="$reviewer_commit+dirty"
fi
{
    echo "date:     $(date -Iseconds)"
    echo "backend:  $backend"
    echo "model:    $model_label"
    echo "reviewer: $reviewer_commit"
    echo "prompt:   $(sed -n "/^prompt='/,/'$/p" "$reviewer" | sha256sum | cut -c1-12)"
} >"$results/meta.txt"
printf 'package\tversion\tcommit\texpected\tverdict\tseconds\n' >"$results/summary.tsv"

pkg_version() {
    local dir="$1" epoch="" ver rel
    if [[ -f "$dir/.SRCINFO" ]]; then
        ver="$(sed -n 's/^\tpkgver = //p' "$dir/.SRCINFO" | head -n1)"
        rel="$(sed -n 's/^\tpkgrel = //p' "$dir/.SRCINFO" | head -n1)"
        epoch="$(sed -n 's/^\tepoch = //p' "$dir/.SRCINFO" | head -n1)"
    else
        ver="$(sed -n 's/^pkgver=//p' "$dir"/*/PKGBUILD "$dir/PKGBUILD" 2>/dev/null | head -n1)"
        rel="$(sed -n 's/^pkgrel=//p' "$dir"/*/PKGBUILD "$dir/PKGBUILD" 2>/dev/null | head -n1)"
    fi
    echo "${epoch:+$epoch:}$ver-$rel"
}

total_ms=0
count=0

run() {
    local label="$1" dir="$2" expect="$3" file verdict start ms secs version commit
    file="$results/${label%% *}.txt"
    start=$(date +%s%3N)
    "$reviewer" "$dir" </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >"$file"
    ms=$(( $(date +%s%3N) - start ))
    verdict="$(grep -m1 -oE 'VERDICT: [A-Z]+' "$file" | cut -d' ' -f2)"
    secs="$(printf '%.1f' "$(bc <<<"scale=2; $ms/1000")")"
    version="$(pkg_version "$dir")"
    commit="$(git -C "$(find "$dir" -maxdepth 2 -name PKGBUILD -printf '%h\n' | head -n1)" \
        rev-parse --short HEAD 2>/dev/null)"
    total_ms=$(( total_ms + ms ))
    count=$(( count + 1 ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$version" "$commit" "$expect" "${verdict:-ERROR}" "$secs" \
        >>"$results/summary.tsv"
    printf '%-24s %-8s %6ss  (expected %s)\n' "$label" "${verdict:-ERROR}" "$secs" "$expect"
}

echo "backend=$backend model=$model_label"
for pkg in "${clean[@]}"; do
    [[ -d "$work/clean/$pkg" ]] && run "$pkg" "$work/clean/$pkg" GREEN
done
run "tidyclip (fake)" "$work/fake/yellow" "YELLOW/RED"
run "fastgrep-bin (fake)" "$work/fake/red" RED

if (( count > 0 )); then
    avg="$(printf '%.1f' "$(bc <<<"scale=2; $total_ms/$count/1000")")"
    echo "average: ${avg}s per package ($count packages)"
    echo "average: ${avg}s" >>"$results/meta.txt"
fi
echo "results: $results"
