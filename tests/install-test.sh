#!/usr/bin/env bash
# install-test.sh — sandboxed install/uninstall validation.
#
# Sets HOME to a tmpdir, drops a fake tmux into the sandbox PATH so the deps
# check passes, runs install.sh --yes / --no-l3 in various modes, asserts the
# expected side effects landed (symlinks, marker blocks, files), then runs
# uninstall.sh and asserts cleanup.
#
# Safe to run anywhere; never touches the real user's $HOME.

set -euo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$_TEST_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_file()      { [[ -f "$1" ]] && pass "exists: $2"      || fail "missing file: $2 ($1)"; }
assert_no_file()   { [[ ! -e "$1" ]] && pass "absent: $2"    || fail "should be gone: $2 ($1)"; }
assert_symlink()   { [[ -L "$1" ]] && pass "symlink: $2"     || fail "missing symlink: $2 ($1)"; }
assert_contains()  { grep -qF -- "$2" "$1" && pass "$3"      || fail "$3 (file: $1, looking for: $2)"; }
assert_absent()    { ! grep -qF -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3 (file: $1, found: $2)"; }

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
sandbox="$(mktemp -d -t vibe-install-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/bin"            # for fake tmux
mkdir -p "$sandbox/dev"            # workspace will go here

# Fake tmux: just print version. Enough to pass `command -v` and `tmux -V`.
cat > "$sandbox/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux 3.5"
exit 0
EOF
chmod +x "$sandbox/bin/tmux"

# Fake workspace. Intentionally has a .env.local with a fake key — install.sh
# must NOT read it (LLM keys live in ~/.config/vibe/env now).
FAKE_WS="$sandbox/dev/my-project"
mkdir -p "$FAKE_WS"
cat > "$FAKE_WS/.env.local" <<'EOF'
# fake env for install test — install.sh must IGNORE this file
DEEPSEEK_API_KEY=sk-SHOULD-NOT-BE-READ-FROM-WORKSPACE
SOME_OTHER_VAR=value
EOF

# Common env: fresh HOME, sandboxed PATH (with fake tmux first), no real keys.
run_install() {
    env -i \
        HOME="$sandbox" \
        PATH="$sandbox/bin:/usr/bin:/bin" \
        VIBE_PROJECT_ROOT="$FAKE_WS" \
        bash "$REPO_DIR/install.sh" "$@"
}
run_uninstall() {
    env -i \
        HOME="$sandbox" \
        PATH="$sandbox/bin:/usr/bin:/bin" \
        bash "$REPO_DIR/uninstall.sh"
}

# ---------------------------------------------------------------------------
# Scenario 1: install --yes (auto-source .env.local, opt in L3 unattended)
# ---------------------------------------------------------------------------
echo
echo "=== Scenario 1: install --yes (with workspace .env.local present) ==="
run_install --yes >/dev/null

assert_symlink "$sandbox/.local/bin/vibe-run"            "~/.local/bin/vibe-run"
assert_symlink "$sandbox/.local/bin/vibe-session-capture" "~/.local/bin/vibe-session-capture"
assert_symlink "$sandbox/.local/bin/vibe-status"         "~/.local/bin/vibe-status"

assert_file "$sandbox/.bashrc" "~/.bashrc"
assert_file "$sandbox/.tmux.conf" "~/.tmux.conf"

# Global config landed; workspace .env.local NOT read.
assert_file "$sandbox/.config/vibe/env"                                              "~/.config/vibe/env created"
assert_contains "$sandbox/.bashrc"   "vibe-coding-auto-resume start === vibe-shell"    "bashrc has vibe-shell marker"
assert_contains "$sandbox/.bashrc"   "source \"\$VIBE_HOME/shell/vibe.bash\""        "vibe-shell sources dispatcher"
assert_contains "$sandbox/.bashrc"   "VIBE_HOME="                                     "VIBE_HOME exported"
assert_contains "$sandbox/.bashrc"   "/vibe/env"                                      "bashrc sources global vibe env"
assert_absent   "$sandbox/.bashrc"   "CC_LLM_PROVIDER=deepseek"                       "install no longer writes provider= line"
assert_absent   "$sandbox/.bashrc"   "SHOULD-NOT-BE-READ-FROM-WORKSPACE"              "install did NOT read workspace .env.local"
assert_contains "$sandbox/.tmux.conf" "allow-passthrough on"                          "tmux.conf has allow-passthrough"
assert_contains "$sandbox/.tmux.conf" "history-limit 50000"                           "tmux.conf has history-limit"

# IMPORTANT: install.sh must NOT touch the workspace by default. That work
# moved to `vibe setup-workspace` (see Scenario 7). Assert install left the
# workspace untouched.
assert_no_file "$FAKE_WS/HANDOFF.md" "install.sh did NOT seed workspace HANDOFF.md"
[ ! -f "$FAKE_WS/CLAUDE.md" ] && pass "install.sh did NOT create workspace CLAUDE.md" \
                              || fail "install.sh wrote to workspace CLAUDE.md"

# ---------------------------------------------------------------------------
# Scenario 2: re-run install (idempotency)
# ---------------------------------------------------------------------------
echo
echo "=== Scenario 2: re-run install --yes (idempotent) ==="
run_install --yes >/dev/null
dup_count="$(grep -c "vibe-coding-auto-resume start === vibe-shell" "$sandbox/.bashrc")"
[ "$dup_count" -eq 1 ] && pass "vibe-shell marker not duplicated (count=$dup_count)" \
                       || fail "vibe-shell marker duplicated (count=$dup_count)"

# ---------------------------------------------------------------------------
# Scenario 3: legacy llm-provider block is cleaned up on re-install
# ---------------------------------------------------------------------------
echo
echo "=== Scenario 3: legacy llm-provider block cleanup ==="
# Inject a stale legacy block into .bashrc (simulating an upgrade from old install)
cat >> "$sandbox/.bashrc" <<EOF
# === vibe-coding-auto-resume start === llm-provider
export CC_LLM_PROVIDER=deepseek
# === vibe-coding-auto-resume end === llm-provider
EOF
run_install --yes >/dev/null
assert_absent "$sandbox/.bashrc" "start === llm-provider" "stale legacy llm-provider block stripped on re-install"
assert_absent "$sandbox/.bashrc" "CC_LLM_PROVIDER="       "legacy CC_LLM_PROVIDER export removed"

# ---------------------------------------------------------------------------
# Scenario 4: user-edited ~/.config/vibe/env is preserved across re-install
# ---------------------------------------------------------------------------
echo
echo "=== Scenario 4: ~/.config/vibe/env preserved across re-install ==="
echo "# user edit marker xyz" >> "$sandbox/.config/vibe/env"
run_install --yes >/dev/null
assert_contains "$sandbox/.config/vibe/env" "user edit marker xyz" \
                "re-install left ~/.config/vibe/env user content alone"

# ---------------------------------------------------------------------------
# Scenario 5: uninstall cleans up everything
# ---------------------------------------------------------------------------
echo
echo "=== Scenario 5: uninstall removes markers + symlinks ==="
# Re-install with L3 then uninstall
run_install --yes >/dev/null
run_uninstall >/dev/null

assert_no_file "$sandbox/.local/bin/vibe-run" "~/.local/bin/vibe-run gone"
assert_no_file "$sandbox/.local/bin/vibe-session-capture" "~/.local/bin/vibe-session-capture gone"
assert_no_file "$sandbox/.local/bin/vibe-status" "~/.local/bin/vibe-status gone"

assert_absent "$sandbox/.bashrc"   "vibe-coding-auto-resume start ==="               "no vibe markers in bashrc"
assert_absent "$sandbox/.tmux.conf" "vibe-coding-auto-resume start ==="               "no vibe markers in tmux.conf"

# ---------------------------------------------------------------------------
# Scenario 7: vibe setup-workspace (opt-in workspace seeding)
# ---------------------------------------------------------------------------
echo
echo "=== Scenario 7: setup-workspace inside a project ==="
run_install --yes >/dev/null   # restore baseline install
# Simulate user cd'ing into the workspace and running setup-workspace
(cd "$FAKE_WS" && env -i HOME="$sandbox" PATH="$sandbox/bin:/usr/bin:/bin" \
    VIBE_HOME="$REPO_DIR" \
    bash "$REPO_DIR/lib/setup-workspace.sh" >/dev/null)
assert_file "$FAKE_WS/HANDOFF.md" "setup-workspace created HANDOFF.md"
assert_file "$FAKE_WS/CLAUDE.md" "setup-workspace created/appended CLAUDE.md"
assert_contains "$FAKE_WS/CLAUDE.md" "vibe-coding-auto-resume start === claude-md-rule" \
                "CLAUDE.md has rule marker after setup-workspace"

# Idempotency: re-run shouldn't dup
(cd "$FAKE_WS" && env -i HOME="$sandbox" PATH="$sandbox/bin:/usr/bin:/bin" \
    VIBE_HOME="$REPO_DIR" \
    bash "$REPO_DIR/lib/setup-workspace.sh" >/dev/null)
dup2="$(grep -c "vibe-coding-auto-resume start === claude-md-rule" "$FAKE_WS/CLAUDE.md")"
[ "$dup2" -eq 1 ] && pass "setup-workspace idempotent (no duplicate marker)" \
                  || fail "setup-workspace duplicated marker (count=$dup2)"

# Teardown reverses
(cd "$FAKE_WS" && env -i HOME="$sandbox" PATH="$sandbox/bin:/usr/bin:/bin" \
    VIBE_HOME="$REPO_DIR" \
    bash "$REPO_DIR/lib/teardown-workspace.sh" >/dev/null)
assert_absent "$FAKE_WS/CLAUDE.md" "vibe-coding-auto-resume start ===" \
              "teardown stripped marker block from CLAUDE.md"
[ ! -f "$FAKE_WS/HANDOFF.md" ] && pass "teardown moved HANDOFF.md aside" \
                               || fail "teardown failed to move HANDOFF.md"
ls "$FAKE_WS"/HANDOFF.md.vibe-bak.* >/dev/null 2>&1 \
    && pass "teardown left HANDOFF backup" \
    || fail "teardown didn't create HANDOFF backup"

# Safety: refuse to run from $HOME
set +e
out="$(cd "$sandbox" && env -i HOME="$sandbox" PATH="/usr/bin:/bin" \
       VIBE_HOME="$REPO_DIR" bash "$REPO_DIR/lib/setup-workspace.sh" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && pass "setup-workspace refuses to run from \$HOME" \
                || fail "setup-workspace ran from \$HOME (rc=$rc)"

# NOTE: Scenarios are numbered Scenario 1, 2, 3, 4, 5, 7 (no 6 below — see note).
# Scenario 6 (missing-deps fail-fast) intentionally NOT tested in sandbox:
# install.sh needs dirname/mkdir/etc. to run at all (line 1 sets REPO_DIR via
# cd $(dirname ...)), and reliably "hiding" tmux from a sandboxed PATH while
# still exposing those utilities is more trouble than it's worth. The check
# itself is a one-liner in install.sh and is inspection-evident.

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "================================================="
echo "$PASS passed, $FAIL failed"
echo "================================================="
[ "$FAIL" -eq 0 ]
