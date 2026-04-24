git-crypt - transparent file encryption in git (narrowin fork)
==============================================================

This is a fork of [AGWA/git-crypt](https://github.com/AGWA/git-crypt) that
includes unmerged upstream pull requests we depend on:

| PR | Description |
|----|-------------|
| [#311](https://github.com/AGWA/git-crypt/pull/311) | Fix handling small files (data integrity bug) |
| [#222](https://github.com/AGWA/git-crypt/pull/222) | Fix multiple worktrees (use common git dir) |
| [#180](https://github.com/AGWA/git-crypt/pull/180) | Merge driver for secret files |
| [#210](https://github.com/AGWA/git-crypt/pull/210) | Don't encrypt empty files, including existing repos with old keys |
| [#332](https://github.com/AGWA/git-crypt/pull/332) | Fix textconv producing empty diffs on Linux |

### Install

Download a binary from [Releases](https://github.com/narrowin/git-crypt/releases):

```sh
mkdir -p ~/.local/bin

# macOS (Apple Silicon)
curl -L -o ~/.local/bin/git-crypt https://github.com/narrowin/git-crypt/releases/download/v0.8.0-narrowin/git-crypt-darwin-arm64

# Linux (amd64)
curl -L -o ~/.local/bin/git-crypt https://github.com/narrowin/git-crypt/releases/download/v0.8.0-narrowin/git-crypt-linux-amd64

chmod +x ~/.local/bin/git-crypt
~/.local/bin/git-crypt --version
# git-crypt 0.8.0-narrowin
```

Or build from source:

```sh
git clone git@github.com:narrowin/git-crypt.git
cd git-crypt
git remote add upstream https://github.com/AGWA/git-crypt.git
./scripts/build-internal.sh
# binary is at ./git-crypt
./git-crypt --version
```

**Dependencies (build only):** C++ compiler, Make, OpenSSL dev headers, Git.
The build script checks for these and prints install hints if anything is missing.

### Switching from upstream git-crypt

If you already have repos unlocked with upstream git-crypt, you must clear the
old filter config before unlocking with this fork. Otherwise `git-crypt unlock`
will fail with `clean filter 'git-crypt' failed`.

Run this **once per repo** that was previously unlocked with upstream:

```sh
git-crypt lock                                       # lock first if currently unlocked
git config --remove-section filter.git-crypt         # remove stale smudge/clean filters
git config --remove-section diff.git-crypt           # remove stale textconv filter
git-crypt unlock                                     # unlock with the new binary
```

After that, lock/unlock works normally.

### Empty encrypted files

This fork stores empty files that match a `git-crypt` filter pattern as true
0-byte Git blobs. Older git-crypt versions stored those files as 22-byte
`GITCRYPT` header blobs. The old blobs contain no secret content, but they can
break `git stash` or `git merge --autostash` with errors such as:

```text
fatal: stash failed
```

All users who commit to repositories using this fork should upgrade to this
binary before making changes.

After upgrading, run:

```sh
git status
```

If an empty file under a git-crypt pattern appears modified, stage and commit it
once:

```sh
git add path/to/empty-file
git commit -m "Normalize empty git-crypt file"
```

Do not migrate keys, re-run `git-crypt init`, or rewrite history for this
change.

Old git-crypt binaries can check out 0-byte empty files, but if an old binary
re-adds one it may turn it back into the old 22-byte blob. Mixed old/new
binaries can therefore cause small back-and-forth commits for empty files. Use
this binary consistently to avoid that churn.

### Merge driver

To enable the merge driver for encrypted files (PR #180), add `merge=git-crypt`
to your `.gitattributes`:

```
secret.* filter=git-crypt diff=git-crypt merge=git-crypt
```

This lets git merge encrypted files as plaintext instead of failing with
binary conflicts.

---

*Everything below is the upstream README.*

---

git-crypt - transparent file encryption in git
==============================================

git-crypt enables transparent encryption and decryption of files in a
git repository.  Files which you choose to protect are encrypted when
committed, and decrypted when checked out.  git-crypt lets you freely
share a repository containing a mix of public and private content.
git-crypt gracefully degrades, so developers without the secret key can
still clone and commit to a repository with encrypted files.  This lets
you store your secret material (such as keys or passwords) in the same
repository as your code, without requiring you to lock down your entire
repository.

git-crypt was written by [Andrew Ayer](https://www.agwa.name) (agwa@andrewayer.name).
For more information, see <https://www.agwa.name/projects/git-crypt>.

Building git-crypt
------------------
See the [INSTALL.md](INSTALL.md) file.


Using git-crypt
---------------

Configure a repository to use git-crypt:

    cd repo
    git-crypt init

Specify files to encrypt by creating a .gitattributes file:

    secretfile filter=git-crypt diff=git-crypt
    *.key filter=git-crypt diff=git-crypt
    secretdir/** filter=git-crypt diff=git-crypt

Like a .gitignore file, it can match wildcards and should be checked into
the repository.  See below for more information about .gitattributes.
Make sure you don't accidentally encrypt the .gitattributes file itself
(or other git files like .gitignore or .gitmodules).  Make sure your
.gitattributes rules are in place *before* you add sensitive files, or
those files won't be encrypted!

Share the repository with others (or with yourself) using GPG:

    git-crypt add-gpg-user USER_ID

`USER_ID` can be a key ID, a full fingerprint, an email address, or
anything else that uniquely identifies a public key to GPG (see "HOW TO
SPECIFY A USER ID" in the gpg man page).  Note: `git-crypt add-gpg-user`
will add and commit a GPG-encrypted key file in the .git-crypt directory
of the root of your repository.

Alternatively, you can export a symmetric secret key, which you must
securely convey to collaborators (GPG is not required, and no files
are added to your repository):

    git-crypt export-key /path/to/key

After cloning a repository with encrypted files, unlock with GPG:

    git-crypt unlock

Or with a symmetric key:

    git-crypt unlock /path/to/key

That's all you need to do - after git-crypt is set up (either with
`git-crypt init` or `git-crypt unlock`), you can use git normally -
encryption and decryption happen transparently.

Current Status
--------------

The latest version of git-crypt is [0.8.0](NEWS.md), released on
2025-09-23.  git-crypt aims to be bug-free and reliable, meaning it
shouldn't crash, malfunction, or expose your confidential data.
However, it has not yet reached maturity, meaning it is not as
documented, featureful, or easy-to-use as it should be.  Additionally,
there may be backwards-incompatible changes introduced before version
1.0.

Security
--------

git-crypt is more secure than other transparent git encryption systems.
git-crypt encrypts files using AES-256 in CTR mode with a synthetic IV
derived from the SHA-1 HMAC of the file.  This mode of operation is
provably semantically secure under deterministic chosen-plaintext attack.
That means that although the encryption is deterministic (which is
required so git can distinguish when a file has and hasn't changed),
it leaks no information beyond whether two files are identical or not.
Other proposals for transparent git encryption use ECB or CBC with a
fixed IV.  These systems are not semantically secure and leak information.

Limitations
-----------

git-crypt relies on git filters, which were not designed with encryption
in mind.  As such, git-crypt is not the best tool for encrypting most or
all of the files in a repository. Where git-crypt really shines is where
most of your repository is public, but you have a few files (perhaps
private keys named *.key, or a file with API credentials) which you
need to encrypt.  For encrypting an entire repository, consider using a
system like [git-remote-gcrypt](https://spwhitton.name/tech/code/git-remote-gcrypt/)
instead.  (Note: no endorsement is made of git-remote-gcrypt's security.)

git-crypt does not encrypt file names, commit messages, symlink targets,
gitlinks, or other metadata.

git-crypt does not hide when a file does or doesn't change, the length
of a file, or the fact that two files are identical (see "Security"
section above).

git-crypt does not support revoking access to an encrypted repository
which was previously granted. This applies to both multi-user GPG
mode (there's no del-gpg-user command to complement add-gpg-user)
and also symmetric key mode (there's no support for rotating the key).
This is because it is an inherently complex problem in the context
of historical data. For example, even if a key was rotated at one
point in history, a user having the previous key can still access
previous repository history. This problem is discussed in more detail in
<https://github.com/AGWA/git-crypt/issues/47>.

Files encrypted with git-crypt are not compressible.  Even the smallest
change to an encrypted file requires git to store the entire changed file,
instead of just a delta.

Although git-crypt protects individual file contents with a SHA-1
HMAC, git-crypt cannot be used securely unless the entire repository is
protected against tampering (an attacker who can mutate your repository
can alter your .gitattributes file to disable encryption).  If necessary,
use git features such as signed tags instead of relying solely on
git-crypt for integrity.

Files encrypted with git-crypt cannot be patched with git-apply, unless
the patch itself is encrypted.  To generate an encrypted patch, use `git
diff --no-textconv --binary`.  Alternatively, you can apply a plaintext
patch outside of git using the patch command.

git-crypt does not work reliably with some third-party git GUIs, such
as [Atlassian SourceTree](https://jira.atlassian.com/browse/SRCTREE-2511)
and GitHub for Mac.  Files might be left in an unencrypted state.

Gitattributes File
------------------

The .gitattributes file is documented in the gitattributes(5) man page.
The file pattern format is the same as the one used by .gitignore,
as documented in the gitignore(5) man page, with the exception that
specifying merely a directory (e.g. `/dir/`) is *not* sufficient to
encrypt all files beneath it.

Also note that the pattern `dir/*` does not match files under
sub-directories of dir/.  To encrypt an entire sub-tree dir/, use `dir/**`:

    dir/** filter=git-crypt diff=git-crypt

The .gitattributes file must not be encrypted, so make sure wildcards don't
match it accidentally.  If necessary, you can exclude .gitattributes from
encryption like this:

    .gitattributes !filter !diff
