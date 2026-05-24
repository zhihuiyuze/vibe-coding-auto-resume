#!/usr/bin/env bash
# vibe-coding-auto-resume installer.
# Idempotent. Never invokes sudo; prints sudo commands as user instructions.
#
# Flags:
#   --yes / -y     Auto-accept L3 LLM opt-in if a key is detected.
#   --no-l3        Force L1+L2 mode even if a key is detected.
#   --help / -h    Show usage.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK_START="# === vibe-coding-auto-resume start ==="
MARK_END="# === vibe-coding-auto-resume end ==="

BASHRC="$HOME/.bashrc"
TMUX_CONF="$HOME/.tmux.conf"

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
auto_yes=0
force_no_l3=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y)  auto_yes=1; shift ;;
        --no-l3)   force_no_l3=1; shift ;;
        --help|-h)
            sed -n '2,8p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "install.sh: unknown flag: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# append_block <file> <tag> <content>
# Appends a marked block to <file> only if a block with that tag is absent.
# Tag is used inside the marker so multiple distinct blocks can coexist.
append_block() {
    local file="$1"
    local tag="$2"
    local content="$3"
    local start="${MARK_START} ${tag}"
    local end="${MARK_END} ${tag}"

    if [ -f "$file" ] && grep -qF "$start" "$file"; then
        return 0
    fi

    mkdir -p "$(dirname "$file")"
    touch "$file"
    # Ensure trailing newline before appending.
    if [ -s "$file" ] && [ "$(tail -c1 "$file" 2>/dev/null)" != "" ]; then
        printf '\n' >> "$file"
    fi
    {
        printf '%s\n' "$start"
        printf '%s\n' "$content"
        printf '%s\n' "$end"
    } >> "$file"
    echo "  + appended '$tag' block to $file"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
echo "==> Checking dependencies"
missing=()
for dep in jq curl tmux; do
    if ! have "$dep"; then
        missing+=("$dep")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required commands: ${missing[*]}"
    echo "Install them and re-run this script:"
    echo "  sudo apt install ${missing[*]}"
    exit 1
fi
echo "  ok: jq, curl, tmux present"

# ---------------------------------------------------------------------------
# 2. Global vibe config (~/.config/vibe/env)
# ---------------------------------------------------------------------------
echo "==> Setting up global vibe config"
VIBE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vibe"
VIBE_ENV_FILE="$VIBE_CONFIG_DIR/env"
TEMPLATE="$REPO_DIR/config/vibe-env.template"
mkdir -p "$VIBE_CONFIG_DIR"
if [ -f "$VIBE_ENV_FILE" ]; then
    echo "  ok: $VIBE_ENV_FILE already exists; leaving it alone"
else
    cp "$TEMPLATE" "$VIBE_ENV_FILE"
    chmod 600 "$VIBE_ENV_FILE"
    echo "  + created $VIBE_ENV_FILE from template (chmod 600)"
    echo "  → edit it later to add DEEPSEEK_API_KEY / other LLM keys for L3"
fi

# Strip any legacy `llm-provider` marker block from a previous install — that
# logic moved into ~/.config/vibe/env (user-owned).
if [ -f "$BASHRC" ] && grep -qF "${MARK_START} llm-provider" "$BASHRC"; then
    tmp_bashrc="$(mktemp)"
    sed "\|${MARK_START} llm-provider|,\|${MARK_END} llm-provider|d" "$BASHRC" > "$tmp_bashrc"
    mv "$tmp_bashrc" "$BASHRC"
    echo "  - removed legacy llm-provider block from $BASHRC (config moved to $VIBE_ENV_FILE)"
fi

# ---------------------------------------------------------------------------
# 3-4. Symlinks into ~/.local/bin
# ---------------------------------------------------------------------------
echo "==> Installing symlinks to ~/.local/bin"
mkdir -p "$HOME/.local/bin"
for tool in vibe-run vibe-session-capture vibe-status; do
    src="$REPO_DIR/bin/$tool"
    dst="$HOME/.local/bin/$tool"
    ln -sf "$src" "$dst"
    echo "  + $dst -> $src"
done

# ---------------------------------------------------------------------------
# 5. PATH
# ---------------------------------------------------------------------------
echo "==> Ensuring ~/.local/bin is on PATH"
case ":${PATH}:" in
    *":$HOME/.local/bin:"*)
        echo "  ok: already on PATH"
        ;;
    *)
        append_block "$BASHRC" "path" 'export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

# ---------------------------------------------------------------------------
# 6. tmux config
# ---------------------------------------------------------------------------
echo "==> Configuring ~/.tmux.conf"
snippet_path="$REPO_DIR/config/tmux.conf.snippet"
if [ ! -f "$snippet_path" ]; then
    echo "  ! missing $snippet_path; skipping tmux config"
else
    snippet_content="$(cat "$snippet_path")"
    append_block "$TMUX_CONF" "tmux" "$snippet_content"
fi

# ---------------------------------------------------------------------------
# 7. vibe shell dispatcher
# ---------------------------------------------------------------------------
echo "==> Installing vibe shell dispatcher"
vibe_shell="$REPO_DIR/shell/vibe.bash"
if [ ! -f "$vibe_shell" ]; then
    echo "  ! missing $vibe_shell; cannot install dispatcher"
    exit 1
fi
# Single source line + VIBE_HOME export so the function can locate scripts.
dispatcher_block="export VIBE_HOME=\"$REPO_DIR\"
# Source user's global vibe config (LLM keys, tunables). \`set -a\` auto-exports
# every assignment so unprefixed KEY=value lines work too. Skip silently if absent.
if [ -f \"\${XDG_CONFIG_HOME:-\$HOME/.config}/vibe/env\" ]; then
    set -a
    # shellcheck source=/dev/null
    . \"\${XDG_CONFIG_HOME:-\$HOME/.config}/vibe/env\"
    set +a
fi
# shellcheck source=/dev/null
source \"\$VIBE_HOME/shell/vibe.bash\""
# Rewrite the dispatcher block on every install so users pick up changes to it.
if [ -f "$BASHRC" ] && grep -qF "${MARK_START} vibe-shell" "$BASHRC"; then
    tmp_bashrc="$(mktemp)"
    sed "\|${MARK_START} vibe-shell|,\|${MARK_END} vibe-shell|d" "$BASHRC" > "$tmp_bashrc"
    mv "$tmp_bashrc" "$BASHRC"
fi
append_block "$BASHRC" "vibe-shell" "$dispatcher_block"

# ---------------------------------------------------------------------------
# 8. CLAUDE.md -> AGENTS.md symlink (safety check)
# ---------------------------------------------------------------------------
echo "==> Verifying CLAUDE.md -> AGENTS.md symlink"
agents_md="$REPO_DIR/AGENTS.md"
claude_md="$REPO_DIR/CLAUDE.md"
if [ -L "$claude_md" ] && [ "$(readlink "$claude_md")" = "AGENTS.md" ]; then
    echo "  ok: symlink already in place"
elif [ -e "$claude_md" ] && [ ! -L "$claude_md" ]; then
    echo "  ! $claude_md exists as a regular file; not overwriting"
elif [ -f "$agents_md" ]; then
    ln -sf "AGENTS.md" "$claude_md"
    echo "  + created symlink $claude_md -> AGENTS.md"
else
    echo "  ! $agents_md missing; skipping symlink"
fi

# NOTE: Earlier versions of install.sh seeded HANDOFF.md and appended a
# rule block to the workspace's CLAUDE.md as part of default install. That was
# wrong: install.sh must not write to other project directories without an
# explicit per-project opt-in. Those steps are now a separate, user-initiated
# subcommand: `vibe setup-workspace` (run from inside the project you want to
# enable). See lib/setup-workspace.sh.

# ---------------------------------------------------------------------------
# 11. Closing summary / manual TODOs
# ---------------------------------------------------------------------------
echo
echo "==> Install complete."
echo
echo "Manual follow-ups (run these yourself if applicable):"
if ! have tmux; then
    echo "  - sudo apt install tmux"
fi
if [ -e /usr/local/bin/claude-auto-resume ]; then
    echo "  - sudo rm /usr/local/bin/claude-auto-resume   # remove old broken tool"
fi
echo "  - source ~/.bashrc   # (or open a new shell) to pick up PATH/CC_LLM_PROVIDER/vibe shell dispatcher"
echo
echo "Next:"
echo "  1. Add LLM keys for L3 (optional but recommended):"
echo "       \$EDITOR $VIBE_ENV_FILE"
echo "  2. source ~/.bashrc"
echo "  3. vibe work [name]   # start/attach a tmux session"
echo "  4. vibe run           # inside tmux, launch claude with auto-resume"
echo
echo "Per-project setup is opt-in. Run \`vibe setup-workspace\` from inside a project"
echo "to create HANDOFF.md + append continuity rules. install.sh never touches other repos."
