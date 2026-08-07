# devenv-installer

One PowerShell script that takes a Windows machine from nothing to a registered
[NixOS-WSL](https://github.com/nix-community/NixOS-WSL) distribution.

Public so the script can be fetched by URL. The environment it bootstraps
([devenv](https://github.com/jyan5422/devenv)) is separate.

## Use

Nothing to download by hand. The installer fetches the NixOS-WSL artifact itself (~550 MB)
and verifies its published sha256.

From PowerShell **as Administrator** — only strictly needed if WSL is not yet installed:

```powershell
irm https://raw.githubusercontent.com/jyan5422/devenv-installer/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If WSL was missing it installs it and stops for a **reboot**; reboot and run the second line
again. Re-running at any point is safe — an existing distribution is detected and skipped.

When it prints your public SSH key, paste it at <https://github.com/settings/ssh/new> (it
opens the page for you), then press Enter. It verifies, then clones over SSH.

That's it. The installer runs the first rebuild itself, as root — no password to set, no
sudo prompt, no flags to remember. Expect it to take a while; it builds the whole system
closure.

Afterwards open a **new** window (`wsl -d NixOS`), because the rebuild changed the default
user and any shell you already had open is still the old one. What's left is git identity,
the deny-list, and authenticating your agent — the installer prints all three.

```powershell
.\install.ps1 -DryRun                      # report what it would do, change nothing
.\install.ps1 -GitName 'X' -GitEmail 'x@y' # override the default git identity
.\install.ps1 -NoGitIdentity               # leave git config alone
.\install.ps1 -SkipRebuild                 # stop after the clone; rebuild yourself
.\install.ps1 -SkipClone                   # register the distro only
.\install.ps1 -NoSshKey                    # do not generate a key
.\install.ps1 -NonInteractive              # never pause for input
.\install.ps1 -Tarball .\nixos.wsl         # use a local artifact instead of downloading
.\install.ps1 -DistroName NixOS-test       # register under a different name
```

## What it does

1. Verifies WSL is the Store build. Installs it (elevated) and stops for a reboot if absent.
   Warns below 2.4.4 and falls back to the legacy `--import` path.
2. Resolves the current NixOS-WSL release through the GitHub API and downloads it, accepting
   either `nixos.wsl` or the pre-2411 `nixos-wsl.tar.gz`. Verifies the byte count and the
   published sha256.
3. Registers the distribution, then confirms it by re-listing rather than trusting the exit
   code.
4. Generates an ed25519 SSH key, prints the public half, opens the GitHub key page, waits
   while you paste it in, then verifies.
5. Clones your config repo — over SSH if the key checks out, which is what makes a **private**
   repo work.
6. Runs the first rebuild as root, so nothing has to prompt for a password.
7. Moves the repo and the SSH key into the new default user's home, reading that username out
   of the flake.
8. Prints what's left: git identity, deny-list, agent auth.

**Every phase checks itself.** Re-running is safe at any point and picks up wherever it got
to — an existing distribution only means the install is done, not the key or the clone. An
earlier version treated "distro exists" as "nothing to do" and silently skipped everything
downstream, including on the re-run after the reboot it had just asked for.

## The home directory move

The image's default user is `nixos`, so that's who clones the repo and owns the new SSH key.
The rebuild then switches the default user to whoever the flake declares. Without step 7 the
new user comes up to an empty home: no repo, no key, and a key registered with GitHub that
appears not to work. The installer reads `wsl.defaultUser` from the flake with `nix eval`
rather than hardcoding a name that lives in someone else's config.

## The SSH key

Generating a key needs no credentials; only registering it does. So the installer makes the
key and hands you the public half, and the only manual part is the paste.

It's idempotent — an existing `~/.ssh/id_ed25519` is read, never regenerated. No passphrase,
because the key is used non-interactively by git and by this script; add one later with
`ssh-keygen -p` if you want it.

Verification matches on GitHub's greeting rather than the exit code, because `ssh -T
git@github.com` exits 1 even when auth succeeds.

## Where it stops, and why

At the first `nixos-rebuild`. That step is interactive, may prompt for a password you haven't
set yet, and is worth watching the first time. Git identity is left alone too — it's a
preference, not something to guess.

One thing that catches everyone: the first rebuild must pass flakes on the command line,
because a freshly imported image is channel-based and ships with them disabled.

```bash
sudo nixos-rebuild switch --flake ~/devenv#wsl \
  --option experimental-features 'nix-command flakes'
```

## Development

`install.ps1` is dot-sourceable — `. .\install.ps1` loads the functions without running
anything, which is how the tests drive it.

CI runs on `windows-latest`: parse check, PSScriptAnalyzer, Pester, and a `-DryRun` that
exercises release resolution against the live GitHub API. That last one fails the day
upstream renames the artifact, which is deliberate.

```powershell
Invoke-Pester ./tests
```

## Licence

MIT.
