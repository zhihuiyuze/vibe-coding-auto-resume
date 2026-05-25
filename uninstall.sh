#!/usr/bin/env bash
# vibe-coding-auto-resume uninstaller.
# Removes symlinks owned by this repo and strips marker blocks from rc files.
# Does NOT remove user content from HANDOFF.md or workspace CLAUDE.md
# (only our marker block is stripped from CLAUDE.md).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK_START="# === vibe-coding-auto-resume start ==="
MARK_END="# === vibe-coding-auto-resume end ==="

BASHRC="$HOME/.bashrc"
TMUX_CONF="$HOME/.tmux.conf"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# strip_blocks <file>
# Removes every line range bounded by MARK_START..MARK_END (inclusive),
# regardless of the trailing tag. No-op when file is absent or has no markers.
strip_blocks() {
    local file="$1"
    [ -f "$file" ] || return 0
    if ! grep -qF "$MARK_START" "$file"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    # Escape regex metacharacters in markers (start with `#` and `=`, neither
    # need escaping in BRE, but be defensive).
    sed "\|${MARK_START}|,\|${MARK_END}|d" "$file" > "$tmp"
    mv "$tmp" "$file"
    echo "  - stripped vibe-coding-auto-resume blocks from $file"
}

# remove_symlink_if_ours <path>
# Removes the symlink only if it resolves into this repo.
remove_symlink_if_ours() {
    local link="$1"
    if [ ! -L "$link" ]; then
        return 0
    fi
    local target
    target="$(readlink -f "$link" 2>/dev/null || true)"
    case "$target" in
        "$REPO_DIR"/*)
            rm -f "$link"
            echo "  - removed symlink $link"
            ;;
        *)
            echo "  ! $link points outside this repo ($target); leaving it alone"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Symlinks
# ---------------------------------------------------------------------------
echo "==> Removing symlinks"
remove_symlink_if_ours "$HOME/.local/bin/vibe-run"
remove_symlink_if_ours "$HOME/.local/bin/vibe-session-capture"
remove_symlink_if_ours "$HOME/.local/bin/vibe-status"
remove_symlink_if_ours "$HOME/.local/bin/vibe-history"
# Legacy names from earlier installs (cleanup if upgrading from a pre-rename install).
remove_symlink_if_ours "$HOME/.local/bin/claude-resume"
remove_symlink_if_ours "$HOME/.local/bin/cc-session-capture"

# ---------------------------------------------------------------------------
# 2. Strip marker blocks from rc files
# ---------------------------------------------------------------------------
echo "==> Stripping marker blocks from rc files"
strip_blocks "$BASHRC"
strip_blocks "$TMUX_CONF"

# ---------------------------------------------------------------------------
# 3. Done
# ---------------------------------------------------------------------------
echo
echo "==> Uninstall complete."
echo
echo "Reload your shell (source ~/.bashrc) for PATH and function changes to take effect."
echo
echo "Not touched (user-owned):"
echo "  - \${XDG_CONFIG_HOME:-~/.config}/vibe/env   (your LLM keys / tunables)"
echo "  - any HANDOFF.md / CLAUDE.md you opted-in via \`vibe setup-workspace\`"
echo "  - the repo at $REPO_DIR itself"
echo
echo "Delete those manually if you want a fully clean state."
