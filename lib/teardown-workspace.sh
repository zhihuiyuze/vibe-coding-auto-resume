# teardown-workspace.sh — reverse of setup-workspace. Strips the marker block from
# CLAUDE.md and moves HANDOFF.md aside. Run FROM INSIDE the project.

set -euo pipefail

TARGET_DIR="$(pwd)"
MARK_START="# === vibe-coding-auto-resume start ==="
MARK_END="# === vibe-coding-auto-resume end ==="

case "$TARGET_DIR" in
    "$HOME"|"$HOME/"|"/"|"")
        echo "vibe teardown-workspace: refuse to operate on $TARGET_DIR" >&2
        exit 1
        ;;
esac

echo "==> Reversing vibe setup in $TARGET_DIR"

claude_md="$TARGET_DIR/CLAUDE.md"
if [ -f "$claude_md" ] && grep -qF "$MARK_START" "$claude_md"; then
    tmp="$(mktemp)"
    sed "\|${MARK_START}|,\|${MARK_END}|d" "$claude_md" > "$tmp"
    mv "$tmp" "$claude_md"
    echo "  - stripped vibe marker blocks from $claude_md"
fi

if [ -f "$TARGET_DIR/HANDOFF.md" ]; then
    backup="$TARGET_DIR/HANDOFF.md.vibe-bak.$(date +%s)"
    mv "$TARGET_DIR/HANDOFF.md" "$backup"
    echo "  - moved HANDOFF.md to $backup (your content preserved)"
fi

echo
echo "==> Done."
