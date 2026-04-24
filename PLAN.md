# git-crypt Fork Build Plan

## Problem Statement

We use git-crypt across many internal projects on both **macOS** and **Linux**
machines. The upstream repository (AGWA/git-crypt) has useful but unmerged pull
requests that we depend on — bug fixes and features open for years with no
movement.

Today there is no structured way to:

- Track which upstream PRs we need
- Build a git-crypt binary that includes those PRs in a rebuildable way
- Keep the integration up to date as upstream moves or PRs change
- Build for both macOS and Linux without ad-hoc manual steps

We want to publish this fork publicly under **github.com/narrowin/git-crypt**
so others in the community can benefit from the same fixes.

### Constraints

- Targets: macOS (native) and Linux (native). Both are first-class. No Windows.
- macOS binaries cannot be produced inside Linux containers — native build required.
- Upstream ships dynamically linked release binaries for Linux via GitHub Actions.
  No macOS binaries are provided upstream. We match upstream's linking approach.
- Upstream has GPL-3.0 license. Fork preserves this.

### PRs to merge

| PR  | Description                              | Category       |
|-----|------------------------------------------|----------------|
| 311 | Fix handling small files                 | Bug fix        |
| 222 | Fix multiple worktrees (use common dir)  | Bug fix        |
| 180 | Merge driver for secret files            | Feature        |
| 210 | Don't encrypt empty files (supersedes #162) | Bug fix     |

### Build dependencies (from upstream INSTALL.md)

| Dependency         | macOS                        | Debian/Ubuntu         |
|--------------------|------------------------------|-----------------------|
| C++11 compiler     | `xcode-select --install`     | `apt install g++`     |
| Make               | included with Xcode CLI      | `apt install make`    |
| OpenSSL dev headers| `brew install openssl`       | `apt install libssl-dev` |
| Git                | included / `brew install git`| `apt install git`     |

### No upstream test coverage

The upstream project has **no automated tests whatsoever**. No test suite, no
`make test` target, no CI test step. The GitHub Actions workflows only compile
release binaries — they don't verify behavior. CONTRIBUTING.md doesn't mention
testing. The binary has no self-test mode.

This means:

- We cannot rely on "tests pass" to validate merged PRs.
- We need our own smoke test that covers the core encrypt/decrypt cycle.
- When merging a PR that fixes an edge case, we add a corresponding test case.

## Solution

### Local build (3 files)

#### 1. `prs.txt` — PR manifest

One PR number per line. Comments with `#`. Blank lines ignored.
**Order is semantically significant** — PRs are merged sequentially, so line
order affects the resulting tree and conflict behavior. Maintain deliberately.

```
# Order matters: PRs are merged top-to-bottom.
311  # Fix handling small files (data integrity bug)
222  # Fix multiple worktrees (use common git dir)
180  # Merge driver for secret files
210  # Don't encrypt empty files (supersedes #162)
```

Plain PR numbers, not refspecs. The script constructs `pull/N/head` internally.
This keeps the file readable — no git plumbing knowledge needed.

#### 2. `scripts/build-internal.sh` — Integration build script

Runs in a **temporary git worktree** (not the user's working tree — never
mutates your checkout or branch state). Does exactly this, in order:

1. **Validate dependencies** — checks that `git`, `make`, a C++ compiler, and
   OpenSSL headers are present. Does NOT install anything. Fails with clear
   per-OS install hints if something is missing.
2. **Create temporary worktree** — creates a disposable worktree from the repo.
   Your working tree and current branch are untouched.
3. **Fetch upstream** — fetches `master` from the upstream remote.
4. **Create clean integration branch** — resets to `upstream/master` inside the
   worktree. This is a throwaway branch, rebuilt every time.
5. **Fetch and merge each PR** — reads `prs.txt`, fetches each PR ref, merges it
   into the integration branch. If a merge fails, stops and names the conflicting
   PR. **Logs the resolved SHA for each PR and upstream HEAD to stdout** so the
   exact source state is recorded.
6. **Build** — runs `make clean && make`. On macOS, discovers Homebrew OpenSSL
   prefix via `brew --prefix openssl` (works on both Apple Silicon `/opt/homebrew`
   and Intel `/usr/local`) and passes the paths via CXXFLAGS/LDFLAGS. The
   binary version is marked as a narrowin fork build before compiling, so
   `git-crypt --version` is distinguishable from upstream.
7. **Test** — runs `scripts/smoke-test.sh` against the freshly built binary.
   If any test fails, the script stops here — no tag, no "success" message.
8. **Copy binary out** — copies the built `git-crypt` binary to the repo root.
9. **Clean up worktree** — removes the temporary worktree.
10. **Optional tag** — with `--tag <name>`, tags the integration branch so the
    exact state is recorded. Only reached if tests pass.

Usage:

```sh
./scripts/build-internal.sh              # rebuild + compile + test
./scripts/build-internal.sh --tag v0.8.0-narrowin.1  # + tag
```

#### 3. `scripts/smoke-test.sh` — End-to-end verification

Upstream has no tests, so we build our own. Pure shell script, no framework,
no dependencies beyond git and the built binary.

Takes the binary path as an argument (defaults to `./git-crypt`).

**Test setup:**
- Each test runs in an isolated temp directory, cleaned up on exit (trap).
- All temp files (including exported keys) stay inside the temp directory.
- Sets repo-local git identity (`user.name`/`user.email`) so tests work on
  machines without global git config (CI runners, fresh setups).

**Core tests (always run):**

1. **Binary check** — `git-crypt --version` exits 0 and identifies the
   narrowin fork build.
2. **Init** — create a temp git repo, run `git-crypt init`, verify
   `.git/git-crypt` directory is created.
3. **Encrypt cycle** — set up `.gitattributes` marking `secret.*` for encryption,
   create `secret.txt` with known content, `git add && git commit`. Verify the
   file in the git object store is not plaintext (should start with
   `\x00GITCRYPT`).
4. **Export key** — `git-crypt export-key $TMPDIR/test.key`, verify key file
   exists and is non-empty.
5. **Lock** — `git-crypt lock`, verify `secret.txt` working copy is now
   encrypted (binary content, not the original plaintext).
6. **Unlock** — `git-crypt unlock $TMPDIR/test.key`, verify `secret.txt` is
   back to the original plaintext content.
7. **Status** — `git-crypt status` exits 0, lists the encrypted file.

**PR-specific tests (one per merged PR):**

- **PR #311 (small files):** Create a 1-byte secret file, run the full
  encrypt/lock/unlock cycle, verify content survives.
- **PR #222 (worktrees):** Create a git worktree, run `git-crypt unlock` in
  the worktree, verify it works independently of the main tree.
- **PR #180 (merge driver):** Create two branches that modify the same secret
  file, merge them, verify git-crypt's merge driver is invoked and produces
  a valid result.
- **PR #210 (empty files):** Create a 0-byte secret file, verify it stays
  empty after lock/unlock and doesn't corrupt.

Convention: when you add a line to `prs.txt`, add a test function to
`smoke-test.sh` if the PR fixes observable behavior. Docs-only or build-only
PRs don't need a test.

**Design:**
- Bash 3.2+ compatible (macOS still ships Bash 3.2 due to GPL-3 licensing).
  No associative arrays, no `|&`, no `mapfile`. No test framework, no extra deps.
- Fails fast — first failure stops and names the failing test.
- Exit code 0 = all pass, non-zero = failure.
- Works identically on macOS and Linux (no GNU-isms).

Usage:

```sh
./scripts/smoke-test.sh              # test ./git-crypt (default)
./scripts/smoke-test.sh ./build/git-crypt  # test a specific binary
```

### What the scripts do NOT do

- Install packages (your machine, your choice)
- Push anything (local only, you decide when to push)
- Manage remotes automatically (you set up `upstream` once)
- Anything with containers, VMs, or CI

### Future: public distribution via GitHub Actions

Not in scope now, but when ready: upstream already has release workflows for
Linux x86_64 and aarch64 that build + upload binaries on tag push. We can adapt
those and add a macOS workflow. The local build script and smoke test are
designed to work both locally and in CI, so this is a drop-in addition later.

## Why This Is the Right Fit

**Proportional to the problem.** The entire build compiles in seconds. The
integration machinery should be equally fast and transparent. Three files,
no new dependencies, no infrastructure.

**Rebuildable > long-lived branch.** A persistent merge branch accumulates hidden
state — old conflict resolutions, stale merge commits, unclear history. Rebuilding
from a PR list means the branch state is always explicit. Conflicts between PRs
or against upstream surface immediately instead of hiding. (This is rebuildable,
not bit-for-bit reproducible — upstream and PR refs can move. The `--tag` flag
pins exact state when it matters.)

**Worktree isolation.** The build script never touches your working tree or
current branch. Everything happens in a temporary git worktree that gets cleaned
up automatically. Safe to run mid-work.

**Native builds, matching upstream.** macOS binaries must be built natively.
Upstream ships dynamically linked Linux binaries — we match that approach.
No containers, no static linking gymnastics, no deviation from upstream.

**Validate, don't install.** Build scripts that run package managers are brittle
and violate the principle of least surprise. Clear error messages with per-OS
install hints respect the operator.

**Test what upstream doesn't.** Upstream has zero automated tests. Our smoke test
covers the core workflow and every edge case we're pulling in via PRs. The test
grows with the PR list: add a PR, add a test.

**Standard practices.** This follows the pattern used by Linux distribution
maintainers (patch queues on top of upstream releases) scaled down to a small
project. Manifest-driven integration, clean rebuilds, explicit dependency
validation, smoke testing — all well-established.

## One-Time Setup (maintainer only)

This section is for the person who manages the fork and runs integration builds.
Consumers of the fork just clone it and run `make`, or download a release binary.

```sh
# 1. Fork AGWA/git-crypt to github.com/narrowin/git-crypt
# 2. Clone the fork:
git clone git@github.com:narrowin/git-crypt.git
cd git-crypt

# 3. Add upstream remote:
git remote add upstream https://github.com/AGWA/git-crypt.git

# 4. Verify:
git remote -v
# origin    git@github.com:narrowin/git-crypt.git (fetch/push)
# upstream  https://github.com/AGWA/git-crypt.git (fetch/push)
```

## Release Workflow

```sh
# Build + test:
./scripts/build-internal.sh --tag v0.8.0-narrowin.1

# Push the integration branch + tag to the fork:
git push origin internal v0.8.0-narrowin.1
```

## Maintenance

- **Upstream merges one of our PRs:** delete the line from `prs.txt`, rebuild.
- **Need a new upstream PR:** add a line to `prs.txt`, rebuild.
- **Upstream releases new version:** update the base, rebuild, check for conflicts.
- **PR force-pushed:** rebuild picks up the new state automatically.
