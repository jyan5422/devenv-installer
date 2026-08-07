# devenv-installer

One PowerShell script that takes a Windows machine from nothing to a working
[NixOS-WSL](https://github.com/nix-community/NixOS-WSL) distribution running
[devenv](https://github.com/jyan5422/devenv).

Public so the script can be fetched by URL — the config repo it bootstraps is private, and a
bootstrapper that lives only inside a repo you cannot yet clone is no use on a fresh machine.

## Use

From PowerShell **as Administrator** (only strictly needed if WSL isn't installed yet):

```powershell
irm https://raw.githubusercontent.com/jyan5422/devenv-installer/main/install.ps1 -OutFile install.ps1
powershell -ep bypass -f install.ps1
```

Nothing to download by hand — it fetches the ~550 MB NixOS-WSL artifact itself and checks the
published sha256.

If WSL was missing it installs it and stops for a **reboot**; reboot and run the second line
again. When it prints your public SSH key, paste it at <https://github.com/settings/ssh/new>
(it opens the page) and press Enter.

Then it runs the first rebuild itself. Expect several minutes of apparent silence — it is
building the whole system closure.

Afterwards open a **new** window: the rebuild changes the default user, so any shell you
already had open is stale.

```powershell
.\install.ps1 -DryRun                 # report what it would do, change nothing
.\install.ps1 -SkipRebuild            # stop after the clone
.\install.ps1 -SkipClone              # register the distro only
.\install.ps1 -NoSshKey               # do not generate a key
.\install.ps1 -FreshKey               # new key even if one exists on Windows
.\install.ps1 -NonInteractive         # never pause for input
.\install.ps1 -NoKeepAlive           # skip the logon keep-alive task
.\install.ps1 -Tarball .\nixos.wsl    # use a local artifact
.\install.ps1 -DistroName NixOS-test  # register under a different name
```

## What it does

1. Verifies WSL is the Store build. Installs it (elevated) and stops for a reboot if absent.
   Warns below 2.4.4 and falls back to `wsl --import`.
2. Resolves the current release through the GitHub API — `nixos.wsl`, or `nixos.aarch64.wsl`
   on ARM — downloads it, and verifies both size and published sha256.
3. Registers the distribution and confirms it by re-listing, rather than trusting the exit code.
4. Reuses `%USERPROFILE%\.ssh\id_ed25519` if present, otherwise generates a key inside the
   distro and copies it back out to Windows so a reinstall does not mint a new one.
5. Waits while you register the key with GitHub, then verifies.
6. Clones the config repo over SSH — the only form that works while it is private — or brings
   an existing clone to `origin`.
7. Runs the first rebuild as root, so nothing prompts for a password that does not exist yet.
8. Moves the repo and SSH key into the new default user's home, reading that username out of
   the flake.
9. Registers a logon task that holds one root session open, so the distro keeps running
   between terminal sessions.
10. Prints what is left: the deny-list, and authenticating the agent.

**Every phase checks itself**, so re-running is safe and resumes wherever it stopped. It will
also adopt a clone stranded in another user's home, which is the state an interrupted first
rebuild leaves behind.

## What it deliberately does not do

**Set your git identity.** devenv enables home-manager's git module, which makes
`~/.gitconfig` a read-only symlink into the nix store — `git config --global` fails there with
*could not lock config file*. Identity is declared in `home/git.nix` instead, which is also
the only place it survives a rebuild.

**Write your deny-list.** `devenv/scripts/scan.sh` blocks commits containing employer content,
reading patterns from `~/.config/devenv/deny-list.txt`. That file deliberately lives in no
repo — a committed list of the strings you must never publish is itself the leak. The
installer creates the directory; the patterns are yours. It fails closed, so a missing file
blocks commits rather than passing silently.

## Things worth knowing

**The base image is minimal.** No `git`, no `ssh`, no `ssh-keygen` until the first rebuild
installs them. The installer resolves what it needs through `nix-shell` in the meantime — and
`nix-shell` rather than `nix run`, because a freshly imported image is channel-based with
flakes off.

**Flakes go on the command line exactly once.** The config enables them permanently, but not
until it has been applied, so the first rebuild has to pass
`--option experimental-features 'nix-command flakes'` itself.

**The first rebuild uses a `path:` flake reference.** Running as root against a clone owned by
another user trips libgit2's dubious-ownership check, and marking the repo safe in root's
gitconfig does not persuade nix's bundled libgit2. `path:` bypasses git entirely. Ordinary
rebuilds keep the normal form — they run as the owner and never hit it.

**WSL stops the distro when the last session detaches**, taking systemd and every service
with it — so an xrdp desktop dies the moment you close the terminal you started it from.
Nothing inside the distro can prevent this; the lifetime is decided on the Windows side. The
installer registers a logon task running `wsl -d NixOS -u root -- sleep infinity`, which keeps
systemd alive with no shell attached. Related but separate: `vmIdleTimeout` in
`%UserProfile%\.wslconfig` governs how long the utility VM lingers, and the machine sleeping
suspends everything regardless.

**A login shell prints a welcome banner** on a fresh image, on every invocation. Every command
the installer runs is fenced with a marker so that banner cannot be mistaken for output.

## Development

`install.ps1` is dot-sourceable — `. .\install.ps1` loads the functions without running
anything, which is how the tests drive it.

CI on `windows-latest` runs: a parse check under **both** pwsh 7 and Windows PowerShell 5.1,
PSScriptAnalyzer, Pester, and a `-DryRun` against the live GitHub API.

Both parse checks matter. `||` is a valid operator in 7 and a syntax error in 5.1, and the
documented invocation is `powershell -File`, which is 5.1. Checking only under 7 let a hard
parse error ship once.

```powershell
Invoke-Pester ./tests
```

## Licence

MIT.
