#!/usr/bin/env bash
#
# smoke-test.sh — End-to-end verification for git-crypt.
#
# Upstream has no tests, so we build our own. Pure shell, no framework,
# no dependencies beyond git and the built binary.
#
# Bash 3.2+ compatible (macOS ships 3.2). No associative arrays, no |&,
# no mapfile, no test framework.
#
# Usage:
#   ./scripts/smoke-test.sh                    # test ./git-crypt (default)
#   ./scripts/smoke-test.sh ./build/git-crypt  # test a specific binary

set -euo pipefail

# Prevent git context from leaking in from the caller (e.g. build worktree)
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES 2>/dev/null || true

GIT_CRYPT="${1:-./git-crypt}"

# Resolve to absolute path
case "$GIT_CRYPT" in
    /*) ;;
    *)  GIT_CRYPT="$(cd "$(dirname "$GIT_CRYPT")" && pwd)/$(basename "$GIT_CRYPT")" ;;
esac

if [ ! -x "$GIT_CRYPT" ]; then
    echo "error: git-crypt binary not found or not executable: $GIT_CRYPT" >&2
    exit 1
fi

TMPDIR_BASE="$(mktemp -d "${TMPDIR:-/tmp}/git-crypt-test.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    rm -rf "$TMPDIR_BASE"
}

trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL: $1" >&2
    if [ -n "${2:-}" ]; then
        echo "        $2" >&2
    fi
    exit 1
}

# Create a fresh git repo with local identity and return its path.
make_repo() {
    local name="${1:-repo}"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.name "Test User"
    git -C "$dir" config user.email "test@example.com"
    echo "$dir"
}

# Set up a repo with git-crypt initialized, .gitattributes for secret.*, and
# an initial commit. Returns the repo path.
make_encrypted_repo() {
    local name="${1:-encrypted}"
    local dir
    dir="$(make_repo "$name")"

    (cd "$dir" && "$GIT_CRYPT" init)

    printf 'secret.* filter=git-crypt diff=git-crypt\n' > "$dir/.gitattributes"
    git -C "$dir" add .gitattributes
    git -C "$dir" commit -q -m "add gitattributes"

    echo "$dir"
}

# Create a secret file, commit it, and export the key.
setup_secret_and_key() {
    local dir="$1"
    local content="${2:-This is secret content.}"
    local filename="${3:-secret.txt}"

    printf '%s' "$content" > "$dir/$filename"
    git -C "$dir" add "$filename"
    git -C "$dir" commit -q -m "add $filename"

    (cd "$dir" && "$GIT_CRYPT" export-key "$TMPDIR_BASE/test.key")
}

# ── Core tests ────────────────────────────────────────────────────────────────

echo "==> Core tests"

# Test 1: Binary check — version exits 0 and identifies the fork build
test_version() {
    local output
    output="$("$GIT_CRYPT" --version 2>&1)" || fail "version" "exit code $?"
    case "$output" in
        git-crypt*[0-9]*.[0-9]*-narrowin*) ;;
        *) fail "version" "unexpected output: $output" ;;
    esac
    pass "version: $output"
}

# Test 2: Init — creates .git/git-crypt
test_init() {
    local dir
    dir="$(make_repo "init-test")"

    (cd "$dir" && "$GIT_CRYPT" init) || fail "init" "exit code $?"

    # PR #222 moves internal state to .git/common/git-crypt
    if [ ! -d "$dir/.git/common/git-crypt" ] && [ ! -d "$dir/.git/git-crypt" ]; then
        fail "init" "git-crypt internal state directory not created"
    fi
    pass "init"
}

# Test 3: Encrypt cycle — committed content is encrypted in object store
test_encrypt() {
    local dir
    dir="$(make_encrypted_repo "encrypt-test")"
    local content="This is secret content."

    printf '%s' "$content" > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "add secret"

    # Check object store — encrypted files start with \x00GITCRYPT
    local blob
    blob="$(git -C "$dir" show HEAD:secret.txt | head -c 10 | xxd -p)"
    case "$blob" in
        00474954435259505400*) ;; # \x00GITCRYPT
        *) fail "encrypt" "blob doesn't start with GITCRYPT header: $blob" ;;
    esac
    pass "encrypt"
}

# Test 4: Export key
test_export_key() {
    local dir
    dir="$(make_encrypted_repo "export-key-test")"

    printf 'secret' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "add secret"

    local keyfile="$TMPDIR_BASE/export-test.key"
    (cd "$dir" && "$GIT_CRYPT" export-key "$keyfile") || fail "export-key" "exit code $?"

    if [ ! -s "$keyfile" ]; then
        fail "export-key" "key file is empty or missing"
    fi
    pass "export-key"
}

# Test 5: Lock
test_lock() {
    local dir
    dir="$(make_encrypted_repo "lock-test")"
    local content="Lock test secret."

    setup_secret_and_key "$dir" "$content"

    (cd "$dir" && "$GIT_CRYPT" lock) || fail "lock" "exit code $?"

    # Encrypted files are larger than plaintext (header + nonce). Compare sizes.
    local plain_len locked_len
    plain_len="${#content}"
    locked_len="$(wc -c < "$dir/secret.txt" | tr -d '[:space:]')"
    if [ "$locked_len" -le "$plain_len" ]; then
        fail "lock" "file size $locked_len not larger than plaintext $plain_len — not encrypted"
    fi
    pass "lock"
}

# Test 6: Unlock
test_unlock() {
    local dir
    dir="$(make_encrypted_repo "unlock-test")"
    local content="Unlock test secret."

    setup_secret_and_key "$dir" "$content"

    (cd "$dir" && "$GIT_CRYPT" lock)
    (cd "$dir" && "$GIT_CRYPT" unlock "$TMPDIR_BASE/test.key") || fail "unlock" "exit code $?"

    local wc
    wc="$(cat "$dir/secret.txt")"
    if [ "$wc" != "$content" ]; then
        fail "unlock" "content mismatch after unlock: got '$wc'"
    fi
    pass "unlock"
}

# Test 7: Status
test_status() {
    local dir
    dir="$(make_encrypted_repo "status-test")"

    printf 'status secret' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "add secret"

    local output
    output="$(cd "$dir" && "$GIT_CRYPT" status 2>&1)" || fail "status" "exit code $?"
    case "$output" in
        *secret.txt*) ;;
        *) fail "status" "secret.txt not listed in status output" ;;
    esac
    pass "status"
}

test_version
test_init
test_encrypt
test_export_key
test_lock
test_unlock
test_status

# ── PR-specific tests ─────────────────────────────────────────────────────────

echo "==> PR-specific tests"

# PR #311: Small files — 1-byte file survives encrypt/lock/unlock
test_pr311_small_files() {
    local dir
    dir="$(make_encrypted_repo "pr311-test")"
    local content="X"

    setup_secret_and_key "$dir" "$content" "secret.small"

    (cd "$dir" && "$GIT_CRYPT" lock)

    local locked_len
    locked_len="$(wc -c < "$dir/secret.small" | tr -d '[:space:]')"
    if [ "$locked_len" -le 1 ]; then
        fail "PR#311 small files" "file size $locked_len after lock — not encrypted"
    fi

    (cd "$dir" && "$GIT_CRYPT" unlock "$TMPDIR_BASE/test.key")

    local wc
    wc="$(cat "$dir/secret.small")"
    if [ "$wc" != "$content" ]; then
        fail "PR#311 small files" "content mismatch after unlock: got '$wc', expected '$content'"
    fi
    pass "PR#311 small files (1-byte file survives lock/unlock)"
}

# PR #222: Worktrees — lock/unlock works independently in a git worktree
test_pr222_worktrees() {
    local dir
    dir="$(make_encrypted_repo "pr222-test")"
    local content="Worktree secret content."

    setup_secret_and_key "$dir" "$content"

    # Create a worktree from HEAD
    local wt_dir="$TMPDIR_BASE/pr222-worktree"
    git -C "$dir" worktree add -q "$wt_dir" HEAD

    # Lock and unlock within the worktree independently
    (cd "$wt_dir" && "$GIT_CRYPT" lock) || fail "PR#222 worktrees" "lock in worktree failed"

    local locked_len
    locked_len="$(wc -c < "$wt_dir/secret.txt" | tr -d '[:space:]')"
    if [ "$locked_len" -le "${#content}" ]; then
        fail "PR#222 worktrees" "file size $locked_len after lock — not encrypted"
    fi

    (cd "$wt_dir" && "$GIT_CRYPT" unlock "$TMPDIR_BASE/test.key") || fail "PR#222 worktrees" "unlock in worktree failed"

    wc="$(cat "$wt_dir/secret.txt")"
    if [ "$wc" != "$content" ]; then
        fail "PR#222 worktrees" "content mismatch in worktree: got '$wc'"
    fi

    # Clean up worktree
    git -C "$dir" worktree remove "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"

    pass "PR#222 worktrees (lock/unlock works in git worktree)"
}

# PR #180: Merge driver — merging branches with secret file changes
test_pr180_merge_driver() {
    local dir
    dir="$(make_encrypted_repo "pr180-test")"

    # Base: a multi-line secret so merge has something to work with
    printf 'line one\nline two\nline three\n' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "add secret"
    (cd "$dir" && "$GIT_CRYPT" export-key "$TMPDIR_BASE/test.key")

    # Update .gitattributes to include merge driver
    printf 'secret.* filter=git-crypt diff=git-crypt merge=git-crypt\n' > "$dir/.gitattributes"
    git -C "$dir" add .gitattributes
    git -C "$dir" commit -q -m "add merge driver attribute"

    local base_branch
    base_branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"

    # Branch A: modify the END of the file
    git -C "$dir" checkout -q -b branch-a
    printf 'line one\nline two\nline three\nbranch A addition\n' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "branch A change"

    # Branch B: modify the BEGINNING of the file (non-overlapping)
    git -C "$dir" checkout -q "$base_branch"
    git -C "$dir" checkout -q -b branch-b
    printf 'branch B addition\nline one\nline two\nline three\n' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "branch B change"

    # Merge branch-a into branch-b — merge driver should decrypt, merge, re-encrypt
    if git -C "$dir" merge --no-edit branch-a 2>/dev/null; then
        # Non-overlapping changes: driver should auto-resolve
        local result
        result="$(cat "$dir/secret.txt")"
        # Verify the merge result contains content from BOTH branches
        case "$result" in
            *"branch A addition"*"branch B addition"*|*"branch B addition"*"branch A addition"*)
                pass "PR#180 merge driver (auto-resolved non-overlapping changes)"
                ;;
            *)
                fail "PR#180 merge driver" "auto-merge didn't contain both changes: $result"
                ;;
        esac
    else
        # If conflict, verify markers are plaintext (not encrypted garbage)
        local markers
        markers="$(cat "$dir/secret.txt")"
        case "$markers" in
            *"<<<<<"*"======"*">>>>>"*)
                # Conflict markers in plaintext — merge driver decrypted correctly
                git -C "$dir" checkout --theirs secret.txt
                git -C "$dir" add secret.txt
                git -C "$dir" commit -q -m "resolve merge" --no-edit
                pass "PR#180 merge driver (plaintext conflict markers — driver working)"
                ;;
            *)
                fail "PR#180 merge driver" "conflict output is not readable plaintext"
                ;;
        esac
    fi
}

# Diff driver — textconv uses 'cat' so diffs show decrypted plaintext
test_diff_driver() {
    local dir
    dir="$(make_encrypted_repo "diff-test")"

    printf 'original secret\n' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "add secret"

    printf 'modified secret\n' > "$dir/secret.txt"
    git -C "$dir" add secret.txt
    git -C "$dir" commit -q -m "modify secret"

    # Verify textconv is set to 'cat' (our fix)
    local textconv
    textconv="$(git -C "$dir" config diff.git-crypt.textconv 2>/dev/null)"
    if [ "$textconv" != "cat" ]; then
        fail "diff driver" "textconv is '$textconv', expected 'cat'"
    fi

    # Compare two commits — must show decrypted plaintext diff
    local diff_output
    diff_output="$(git -C "$dir" diff HEAD~1 HEAD -- secret.txt 2>&1)"

    case "$diff_output" in
        *"-original secret"*"+modified secret"*)
            pass "diff driver (shows decrypted plaintext in diffs)"
            ;;
        *"Binary"*)
            fail "diff driver" "diff shows raw binary — textconv not working"
            ;;
        *)
            fail "diff driver" "expected decrypted diff, got: $diff_output"
            ;;
    esac
}

# PR #210: Empty files — 0-byte file stays empty after lock/unlock (supersedes #162)
test_pr210_empty_files() {
    local dir
    dir="$(make_encrypted_repo "pr210-test")"

    # Create an empty secret file
    touch "$dir/secret.empty"
    git -C "$dir" add secret.empty
    git -C "$dir" commit -q -m "add empty secret"

    # The committed blob should be empty (not encrypted) — that's the #210 fix
    local blob_size
    blob_size="$(git -C "$dir" cat-file -s HEAD:secret.empty)"
    if [ "$blob_size" != "0" ]; then
        fail "PR#210 empty files" "committed blob is $blob_size bytes (should be 0 — not encrypted)"
    fi

    (cd "$dir" && "$GIT_CRYPT" export-key "$TMPDIR_BASE/test.key")

    (cd "$dir" && "$GIT_CRYPT" lock)

    # After lock, empty file should remain empty (not corrupted)
    local size
    size="$(wc -c < "$dir/secret.empty" | tr -d '[:space:]')"
    if [ "$size" != "0" ]; then
        fail "PR#210 empty files" "empty file became $size bytes after lock"
    fi

    (cd "$dir" && "$GIT_CRYPT" unlock "$TMPDIR_BASE/test.key")

    size="$(wc -c < "$dir/secret.empty" | tr -d '[:space:]')"
    if [ "$size" != "0" ]; then
        fail "PR#210 empty files" "empty file became $size bytes after unlock"
    fi

    # Verify non-empty files next to the empty one still encrypt properly
    printf 'not empty' > "$dir/secret.notempty"
    git -C "$dir" add secret.notempty
    git -C "$dir" commit -q -m "add non-empty secret"

    local notempty_blob
    notempty_blob="$(git -C "$dir" cat-file -p HEAD:secret.notempty | head -c 10 | xxd -p)"
    case "$notempty_blob" in
        00474954435259505400*) ;; # \x00GITCRYPT header — encrypted
        *) fail "PR#210 empty files" "non-empty file wasn't encrypted (regression)" ;;
    esac

    pass "PR#210 empty files (0-byte stays empty, non-empty still encrypts)"
}

test_pr311_small_files
test_pr222_worktrees
test_pr180_merge_driver
test_diff_driver
test_pr210_empty_files

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==> All tests passed ($PASS_COUNT/$PASS_COUNT)"
