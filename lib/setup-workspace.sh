# setup-workspace.sh — opt-in per-project enablement, invoked by `vibe setup-workspace`.
# Run FROM INSIDE the project you want to enable. Never invoked by install.sh.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$(pwd)"
MARK_START="# === vibe-coding-auto-resume start ==="
MARK_END="# === vibe-coding-auto-resume end ==="

# Safety rail: only touch the cwd. Don't allow setup-workspace from $HOME or /
case "$TARGET_DIR" in
    "$HOME"|"$HOME/"|"/"|"")
        echo "vibe setup-workspace: refuse to seed $TARGET_DIR (cd into a real project dir first)" >&2
        exit 1
        ;;
esac

echo "==> Enabling vibe in $TARGET_DIR"

# 1. HANDOFF.md
handoff_template="$REPO_DIR/config/handoff-template.md"
if [ ! -f "$handoff_template" ]; then
    echo "  ! template missing at $handoff_template"; exit 1
fi
if [ -f "$TARGET_DIR/HANDOFF.md" ]; then
    echo "  ok: HANDOFF.md already exists; leaving it alone"
else
    cp "$handoff_template" "$TARGET_DIR/HANDOFF.md"
    echo "  + created $TARGET_DIR/HANDOFF.md"
fi

# 2. CLAUDE.md rule (append marker block; idempotent)
rule_path="$REPO_DIR/config/claude-md-rule.md"
claude_md="$TARGET_DIR/CLAUDE.md"
start="${MARK_START} claude-md-rule"
end="${MARK_END} claude-md-rule"

if [ ! -f "$rule_path" ]; then
    echo "  ! rule missing at $rule_path"; exit 1
fi

if [ -f "$claude_md" ] && grep -qF "$start" "$claude_md"; then
    echo "  ok: CLAUDE.md already has the vibe rule block; skipping"
else
    touch "$claude_md"
    if [ -s "$claude_md" ] && [ "$(tail -c1 "$claude_md" 2>/dev/null)" != "" ]; then
        printf '\n' >> "$claude_md"
    fi
    {
        printf '%s\n' "$start"
        cat "$rule_path"
        printf '\n%s\n' "$end"
    } >> "$claude_md"
    echo "  + appended rule block to $claude_md"
fi

echo
echo "==> Done. To revert: vibe teardown-workspace (or manually delete the marker block + HANDOFF.md)."
