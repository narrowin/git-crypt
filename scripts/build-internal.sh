#!/usr/bin/env bash
#
# build-internal.sh — Build git-crypt with upstream PRs merged in.
#
# Runs entirely in a temporary git worktree. Never touches your working tree
# or current branch. Safe to run mid-work.
#
# Usage:
#   ./scripts/build-internal.sh                          # rebuild + compile + test
#   ./scripts/build-internal.sh --tag v0.8.0-narrowin.1  # + tag

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
PR_FILE="$REPO_ROOT/prs.txt"
TAG_NAME=""
WORKTREE_DIR=""
INTEGRATION_BRANCH="internal"
PR_LOG=""

# ── Argument parsing ──────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            shift
            if [ $# -eq 0 ]; then
                echo "error: --tag requires a tag name" >&2
                exit 1
            fi
            TAG_NAME="$1"
            shift
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "usage: $0 [--tag <name>]" >&2
            exit 1
            ;;
    esac
done

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
        echo "==> Cleaning up worktree..."
        git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
    fi
    # Prune stale worktree metadata
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
}

trap cleanup EXIT

# ── Step 1: Validate dependencies ────────────────────────────────────────────

echo "==> Checking dependencies..."

OS="$(uname -s)"
MISSING=""

# Git
if ! command -v git >/dev/null 2>&1; then
    MISSING="$MISSING git"
fi

# Make
if ! command -v make >/dev/null 2>&1; then
    MISSING="$MISSING make"
fi

# C++ compiler
CXX=""
if command -v g++ >/dev/null 2>&1; then
    CXX="g++"
elif command -v c++ >/dev/null 2>&1; then
    CXX="c++"
elif command -v clang++ >/dev/null 2>&1; then
    CXX="clang++"
else
    MISSING="$MISSING c++(compiler)"
fi

# OpenSSL headers
OPENSSL_FOUND=false
if [ "$OS" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1; then
        OPENSSL_PREFIX="$(brew --prefix openssl 2>/dev/null || true)"
        if [ -n "$OPENSSL_PREFIX" ] && [ -d "$OPENSSL_PREFIX/include/openssl" ]; then
            OPENSSL_FOUND=true
        fi
    fi
else
    # Linux: check standard paths
    if [ -f /usr/include/openssl/evp.h ] || pkg-config --exists openssl 2>/dev/null; then
        OPENSSL_FOUND=true
    fi
fi

if [ "$OPENSSL_FOUND" = false ]; then
    MISSING="$MISSING openssl(headers)"
fi

if [ -n "$MISSING" ]; then
    echo "error: missing dependencies:$MISSING" >&2
    echo "" >&2
    if [ "$OS" = "Darwin" ]; then
        echo "  macOS install hints:" >&2
        echo "    xcode-select --install          # C++ compiler + make" >&2
        echo "    brew install openssl             # OpenSSL dev headers" >&2
        echo "    brew install git                 # Git (or use Xcode's)" >&2
    else
        echo "  Debian/Ubuntu install hints:" >&2
        echo "    sudo apt install g++ make libssl-dev git" >&2
    fi
    exit 1
fi

echo "    dependencies OK"

# ── Step 2: Fetch upstream ────────────────────────────────────────────────────

echo "==> Fetching upstream..."
git -C "$REPO_ROOT" fetch upstream

# ── Step 3: Create temporary worktree ─────────────────────────────────────────

WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/git-crypt-build.XXXXXX")"
echo "==> Creating worktree at $WORKTREE_DIR..."

# Remove any leftover integration branch from a previous run
git -C "$REPO_ROOT" branch -D "$INTEGRATION_BRANCH" 2>/dev/null || true

git -C "$REPO_ROOT" worktree add --detach "$WORKTREE_DIR" upstream/master
cd "$WORKTREE_DIR"

UPSTREAM_SHA="$(git rev-parse HEAD)"
echo "    upstream/master: $UPSTREAM_SHA"

# ── Step 4: Create clean integration branch ───────────────────────────────────

echo "==> Creating integration branch..."
git checkout -b "$INTEGRATION_BRANCH"

# ── Step 5: Fetch and merge each PR ───────────────────────────────────────────

if [ ! -f "$PR_FILE" ]; then
    echo "error: $PR_FILE not found" >&2
    exit 1
fi

echo "==> Merging PRs from $PR_FILE..."

while IFS= read -r line || [ -n "$line" ]; do
    # Strip comments and whitespace
    pr="$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')"
    [ -z "$pr" ] && continue

    echo "    PR #$pr: fetching..."
    git -C "$REPO_ROOT" fetch upstream "pull/$pr/head:pr/$pr" --force

    PR_SHA="$(git -C "$REPO_ROOT" rev-parse "pr/$pr")"
    echo "    PR #$pr: $PR_SHA — merging..."

    if ! git merge --no-edit "pr/$pr"; then
        # Merge had conflicts. Abort and retry with -X ours (favor earlier PRs).
        git merge --abort

        echo "    PR #$pr: retrying with -X ours (earlier PRs take priority)..."
        if ! git merge --no-edit -X ours "pr/$pr"; then
            # -X ours resolves content conflicts but not modify/delete.
            # Auto-resolve remaining doc-file conflicts; fail on code conflicts.
            HAS_CODE_CONFLICT=false
            for conflict_file in $(git diff --name-only --diff-filter=U 2>/dev/null); do
                case "$conflict_file" in
                    *.md|*.txt|README|NEWS|INSTALL|CONTRIBUTING*|doc/*|*.rst)
                        echo "    PR #$pr: auto-resolving doc conflict in $conflict_file (keeping upstream)"
                        git checkout --ours -- "$conflict_file" 2>/dev/null && git add "$conflict_file" \
                            || { git rm -f "$conflict_file" 2>/dev/null || true; }
                        ;;
                    *)
                        HAS_CODE_CONFLICT=true
                        echo "    PR #$pr: CODE conflict in $conflict_file" >&2
                        ;;
                esac
            done

            if [ "$HAS_CODE_CONFLICT" = true ]; then
                echo "" >&2
                echo "error: merge conflict on PR #$pr (code files)" >&2
                echo "  Resolve manually or reorder PRs in prs.txt" >&2
                exit 1
            fi

            # All conflicts resolved — complete the merge
            git commit --no-edit
        fi
    fi

    PR_LOG="${PR_LOG:+$PR_LOG
}    PR #$pr: $PR_SHA"

    echo "    PR #$pr: merged"
done < "$PR_FILE"

# Capture the integration commit SHA now — before build/test/cleanup.
INTEGRATION_SHA="$(git rev-parse HEAD)"

# ── Step 6: Build ────────────────────────────────────────────────────────────

echo "==> Building..."
if [ "$OS" = "Darwin" ]; then
    OPENSSL_PREFIX="$(brew --prefix openssl)"
    export CXXFLAGS="-I${OPENSSL_PREFIX}/include ${CXXFLAGS:-}"
    export LDFLAGS="-L${OPENSSL_PREFIX}/lib ${LDFLAGS:-}"
    echo "    macOS: using OpenSSL from $OPENSSL_PREFIX"
fi

make clean
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"

echo "    build OK"

# ── Step 7: Test ──────────────────────────────────────────────────────────────

echo "==> Running smoke tests..."

if [ ! -f "$SCRIPT_DIR/smoke-test.sh" ]; then
    echo "error: $SCRIPT_DIR/smoke-test.sh not found" >&2
    exit 1
fi

# Run from / to prevent git context leaking from the build worktree
if ! (cd / && bash "$SCRIPT_DIR/smoke-test.sh" "$WORKTREE_DIR/git-crypt"); then
    echo "" >&2
    echo "error: smoke tests failed — not proceeding" >&2
    exit 1
fi

echo "    smoke tests passed"

# ── Step 8: Copy binary out ──────────────────────────────────────────────────

echo "==> Copying binary to $REPO_ROOT/git-crypt..."
cp "$WORKTREE_DIR/git-crypt" "$REPO_ROOT/git-crypt"
chmod +x "$REPO_ROOT/git-crypt"

# ── Step 9: Clean up (handled by trap) ────────────────────────────────────────

# ── Step 10: Optional tag ─────────────────────────────────────────────────────

if [ -n "$TAG_NAME" ]; then
    echo "==> Tagging as $TAG_NAME..."
    git -C "$REPO_ROOT" tag "$TAG_NAME" "$INTEGRATION_SHA"
    echo "    tagged $INTEGRATION_SHA as $TAG_NAME"
fi

echo ""
echo "==> Done. Binary at: $REPO_ROOT/git-crypt"
echo "    Build provenance:"
echo "    upstream/master: $UPSTREAM_SHA"
echo "$PR_LOG"
echo "    integration:     $INTEGRATION_SHA"
