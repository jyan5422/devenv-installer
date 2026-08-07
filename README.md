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

Then, inside the distro:

```bash
passwd
sudo nixos-rebuild switch --flake ~/devenv#wsl \
  --option experimental-features 'nix-command flakes'
```

Close and reopen the shell afterwards — the rebuild changes the default user.

```powershell
.\install.ps1 -DryRun                      # report what it would do, change nothing
.\install.ps1 -SkipClone                   # register the distro only
.\install.ps1 -NoSshKey                    # do not generate a key
.\install.ps1 -NonInteractive              # never pause for input
.\install.ps1 -Tarball .\nixos.wsl         # use a local artifact instead of downloading
.\install.ps1 -DistroName NixOS-test       # register under a different name
```

## What it does

1. Verifies WSL is the Store build. Installs it (elevated) and stops for a reboot if absent.
   Warns below 2.4.4 and falls back to the legacy `--import` path.
2. Exits cleanly if a distribution of that name already exists. Re-running is safe.
3. Resolves the current NixOS-WSL release through the GitHub API and downloads it, accepting
   either `nixos.wsl` or the pre-2411 `nixos-wsl.tar.gz`, and verifies the byte count.
4. Registers the distribution, then confirms it by re-listing rather than trusting the exit
   code.
5. Generates an ed25519 SSH key inside the distro, prints the public half, opens the GitHub
   key page, and waits while you paste it in. Then verifies.
6. Clones your config repo — over SSH if the key checks out, which is what makes a **private**
   repo work.
7. Prints what's left.

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
