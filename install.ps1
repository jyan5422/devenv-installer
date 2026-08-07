#Requires -Version 5.1
<#
.SYNOPSIS
  Gets a Windows machine from nothing to a registered NixOS-WSL distribution.

.DESCRIPTION
  Self-contained and safe to re-run. Downloads the current NixOS-WSL release itself,
  so nothing needs to be cloned first.

  Stops at the credential boundary. Enabling WSL2, fetching the release, and registering
  the distribution need no authentication. Cloning a config repo and rebuilding do, and
  the rebuild is interactive besides, so both are left to you and printed at the end.

  Dot-source it (. .\install.ps1) to load the functions without running anything --
  that is how the test suite exercises it.

.EXAMPLE
  irm https://raw.githubusercontent.com/jyan5422/devenv-installer/main/install.ps1 -OutFile install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
  # Register the distro but do not attempt a clone
  .\install.ps1 -SkipClone
#>
[CmdletBinding()]
param(
  [string]$DistroName  = "NixOS",
  [string]$InstallPath = "$env:LOCALAPPDATA\WSL\NixOS",
  [string]$RepoUrl     = "https://github.com/jyan5422/devenv.git",
  [string]$CloneTo     = "devenv",

  # Use an already-downloaded artifact instead of fetching the latest release.
  [string]$Tarball,

  # Register the distribution but skip the clone.
  [switch]$SkipClone,

  # Comment baked into the generated SSH key, so it is identifiable in GitHub's list.
  [string]$Email = "$env:USERNAME@$env:COMPUTERNAME",

  # Do not create an SSH key at all.
  [switch]$NoSshKey,

  # Never pause for input. The key is still generated and printed; the script just
  # will not wait for you to register it.
  [switch]$NonInteractive,

  # Generate a new keypair even if one already exists on the Windows side.
  [switch]$FreshKey,

  # Stop after the clone instead of running the first rebuild. The rebuild is slow
  # and builds the whole system closure, so this exists for when you want to watch it
  # yourself or edit the config before it is applied.
  [switch]$SkipRebuild,

  # Report what would happen and exit. Used by CI, which has no WSL.
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow }

function ConvertTo-WslVersion {
  <#
    Pulls the version out of `wsl --version` output. Split from the caller so it can
    be tested without WSL present.
  #>
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  if ($Raw -match 'WSL version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)') {
    return [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
  }
  return $null
}

function Get-WslVersion {
  # `wsl --version` exists only on the Store build of WSL. Its absence means the old
  # in-Windows component, which cannot host a WSL2 distribution.
  try { $raw = (& wsl.exe --version 2>$null) -join "`n" } catch { return $null }
  ConvertTo-WslVersion -Raw $raw
}

function Get-InstalledDistros {
  # The leading commas are load-bearing. PowerShell unrolls collections on output, so
  # a bare `return @()` emits nothing at all and the caller gets $null, not an empty
  # array. `,@()` wraps it so exactly one level of unrolling leaves the array intact.
  try { $raw = & wsl.exe --list --quiet 2>$null } catch { return ,@() }
  if (-not $raw) { return ,@() }
  ,@($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetArchName {
  # Releases carry both x86_64 (nixos.wsl) and arm64 (nixos.aarch64.wsl) artifacts.
  param([string]$Arch = $env:PROCESSOR_ARCHITECTURE)
  if ($Arch -match 'ARM64') { return 'nixos.aarch64.wsl' }
  return 'nixos.wsl'
}

function Resolve-NixosWslAsset {
  <#
    Returns the current release artifact as @{ Tag; Name; Url; Size; Sha256Url }.
    Named nixos.wsl since release 2411; nixos-wsl.tar.gz before that. Accepting the
    old name too means a rename fails loudly rather than silently.
  #>
  [CmdletBinding()]
  param(
    [string]$ApiUrl = "https://api.github.com/repos/nix-community/NixOS-WSL/releases/latest",
    [string]$AssetName = (Get-TargetArchName)
  )
  $headers = @{ "User-Agent" = "devenv-installer"; "Accept" = "application/vnd.github+json" }
  $release = Invoke-RestMethod -Uri $ApiUrl -Headers $headers

  $asset = $release.assets |
    Where-Object { $_.name -eq $AssetName -or $_.name -eq "nixos-wsl.tar.gz" } |
    Select-Object -First 1

  if (-not $asset) {
    throw "No '$AssetName' asset in release '$($release.tag_name)'. Download it by hand from https://github.com/nix-community/NixOS-WSL/releases/latest and pass -Tarball."
  }

  $sha = $release.assets | Where-Object { $_.name -eq "$($asset.name).sha256" } | Select-Object -First 1

  [pscustomobject]@{
    Tag       = $release.tag_name
    Name      = $asset.name
    Url       = $asset.browser_download_url
    Size      = $asset.size
    Sha256Url = $(if ($sha) { $sha.browser_download_url } else { $null })
  }
}

function Test-ArtifactHash {
  <#
    Upstream publishes a `<name>.sha256` next to each artifact, in the usual
    "<hash>  <filename>" shape. Returns $true when it matches, $false when it does
    not, and $null when there is nothing to check against -- the caller decides how
    strict to be, rather than a missing file silently reading as success.
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Sha256Url
  )
  if (-not $Sha256Url) { return $null }
  $expected = ((Invoke-RestMethod -Uri $Sha256Url -Headers @{ "User-Agent" = "devenv-installer" }) -split '\s+')[0]
  if (-not $expected) { return $null }
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  return ($actual -ieq $expected)
}

function ConvertTo-Base64Script {
  <#
    Encodes a shell script as base64 so it can cross PowerShell -> wsl.exe -> bash as a
    single opaque token.

    Passing a multi-line script straight to `bash -lc` does not survive that chain:
    newlines and quoting get mangled somewhere in native-argument handling, and the
    tail of the script can end up being parsed by PowerShell instead. The tell is a
    capitalised "Cat:" in the output -- that is Get-Content, not /bin/cat.
  #>
  param([Parameter(Mandatory)][string]$Script)
  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
}

function Get-DecodeCommand {
  # Single-line, single-quoted, no newlines -- nothing left for either shell to mangle.
  param([Parameter(Mandatory)][string]$Base64)
  "echo '$Base64' | base64 -d | bash -l"
}

function Select-AfterMarker {
  <#
    Returns the lines after the last occurrence of $Marker, or everything if the marker
    is absent.

    Needed because `bash -l` sources login profiles, and a freshly imported NixOS-WSL
    image prints a multi-line welcome banner from one of them -- on every single
    invocation. Without this, `whoami` returns the banner with the username glued on
    the end, and the caller cheerfully builds a path out of it.
  #>
  param(
    [string[]]$Lines,
    [Parameter(Mandatory)][string]$Marker
  )
  if (-not $Lines) { return ,@() }
  $idx = -1
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match [regex]::Escape($Marker)) { $idx = $i }
  }
  if ($idx -lt 0) { return @($Lines) }
  if ($idx -ge $Lines.Count - 1) { return ,@() }
  return @($Lines[($idx + 1)..($Lines.Count - 1)])
}

function Invoke-InDistro {
  <#
    Runs a shell script inside the distribution. Always goes through base64 -- see
    ConvertTo-Base64Script. Output is fenced by a marker so login-shell noise cannot
    be mistaken for the command's own output. Sets $script:LastDistroExitCode.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$Script,
    [string]$User
  )
  $marker = '@@DEVENV_BEGIN@@'
  # The marker is printed by the script itself, so anything a login profile emitted
  # while starting the shell is already behind us by the time it appears.
  $wrapped = "printf '%s\n' '$marker'`n$Script"
  $cmd = Get-DecodeCommand -Base64 (ConvertTo-Base64Script -Script $wrapped)

  $raw = if ($User) {
    & wsl.exe -d $DistroName -u $User -- bash -lc $cmd
  } else {
    & wsl.exe -d $DistroName -- bash -lc $cmd
  }
  $script:LastDistroExitCode = $LASTEXITCODE
  return (Select-AfterMarker -Lines @($raw) -Marker $marker)
}

function ConvertTo-SshUrl {
  <#
    https://github.com/owner/repo(.git) -> git@github.com:owner/repo.git
    Anything else is returned unchanged, so a URL that is already SSH, or on a host
    we do not know, passes through untouched.
  #>
  param([string]$Url)
  if ($Url -match '^https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$') {
    return "git@github.com:$($Matches[1])/$($Matches[2]).git"
  }
  return $Url
}

function Get-WindowsSshKeyPath {
  # Windows ships OpenSSH and uses the same conventional location.
  param([string]$Home_ = $env:USERPROFILE)
  Join-Path $Home_ ".ssh\id_ed25519"
}

function Copy-KeyIntoDistro {
  <#
    Pushes a Windows-side keypair into the distro. Goes through base64 rather than
    /mnt/c so the file lands on ext4 with real permissions -- ssh refuses to use a key
    it considers world-readable, and the Windows mount cannot express 0600.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$PrivatePath
  )
  if (-not (Test-Path -LiteralPath $PrivatePath)) { return $false }
  $pubPath = "$PrivatePath.pub"
  if (-not (Test-Path -LiteralPath $pubPath)) { return $false }

  $priv = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PrivatePath))
  $pub  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pubPath))

  $sh = @'
set -e
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
echo 'PRIVB64' | base64 -d > "$HOME/.ssh/id_ed25519"
echo 'PUBB64'  | base64 -d > "$HOME/.ssh/id_ed25519.pub"
chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub"
'@.Replace('PRIVB64', $priv).Replace('PUBB64', $pub)

  Invoke-InDistro -DistroName $DistroName -Script $sh | Out-Null
  return ($script:LastDistroExitCode -eq 0)
}

function Test-Base64String {
  # Cheap shape check before handing anything to FromBase64String, which throws rather
  # than returning null on bad input.
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value -match '^[A-Za-z0-9+/]+={0,2}$') -and ($Value.Length % 4 -eq 0)
}

function Copy-KeyOutOfDistro {
  <#
    Saves a distro-generated key back to Windows so `wsl --unregister` does not destroy
    it -- otherwise every reinstall mints a new key and leaves another dead entry in
    your GitHub settings.

    Best-effort by contract. This is a convenience, and it must never be able to fail
    the install: an earlier version parsed the output positionally, met something that
    was not base64, and threw out of the whole run.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$PrivatePath
  )
  try {
    # Delimited, not positional. A login shell can print banners, and nix can print
    # progress, so "the first line" is not a safe assumption.
    $sh = @'
printf '@@PRIV@@\n'
base64 -w0 "$HOME/.ssh/id_ed25519" 2>/dev/null; printf '\n'
printf '@@PUB@@\n'
base64 -w0 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null; printf '\n'
'@
    $out = @(Invoke-InDistro -DistroName $DistroName -Script $sh)
    if ($script:LastDistroExitCode -ne 0) { return $false }

    $priv = $null; $pub = $null
    for ($i = 0; $i -lt $out.Count; $i++) {
      if ($out[$i] -eq '@@PRIV@@' -and $i + 1 -lt $out.Count) { $priv = $out[$i + 1].Trim() }
      if ($out[$i] -eq '@@PUB@@'  -and $i + 1 -lt $out.Count) { $pub  = $out[$i + 1].Trim() }
    }

    if (-not (Test-Base64String $priv) -or -not (Test-Base64String $pub)) { return $false }

    $dir = Split-Path -Parent $PrivatePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllBytes($PrivatePath, [Convert]::FromBase64String($priv))
    [IO.File]::WriteAllBytes("$PrivatePath.pub", [Convert]::FromBase64String($pub))
    return $true
  } catch {
    return $false
  }
}

function New-SshKeyInDistro {
  <#
    Creates an ed25519 key inside the distro if one is not already there, and returns
    the public half. Idempotent -- an existing key is read, never regenerated.

    No passphrase: the key is used non-interactively by git and by this script, and a
    passphrase on a single-user WSL box mostly buys prompts. Add one later with
    `ssh-keygen -p` if you want it.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$Comment
  )

  # Everything to stdout: a failure here used to return $null with no reason, which is
  # useless to whoever has to fix it. The public key is picked out by prefix afterwards.
  #
  # Fallback order matters. A freshly imported image is channel-based with flakes off,
  # so nix-shell (channels) is likelier to work than nix run (flakes) -- try it first.
  $keyScript = @'
exec 2>&1
KEY="$HOME/.ssh/id_ed25519"
echo "diag: user=$(whoami) home=$HOME"
mkdir -p "$HOME/.ssh" || echo "diag: mkdir failed"
chmod 700 "$HOME/.ssh" 2>/dev/null

if [ ! -f "$KEY" ]; then
  if command -v ssh-keygen >/dev/null 2>&1; then
    echo "diag: using system ssh-keygen"
    ssh-keygen -t ed25519 -N "" -C "COMMENT" -f "$KEY" || echo "diag: ssh-keygen failed rc=$?"
  elif command -v nix-shell >/dev/null 2>&1; then
    echo "diag: no ssh-keygen; trying nix-shell -p openssh"
    nix-shell -p openssh --run "ssh-keygen -t ed25519 -N '' -C 'COMMENT' -f '$KEY'" \
      || echo "diag: nix-shell path failed rc=$?"
  else
    echo "diag: no ssh-keygen and no nix-shell; trying nix run"
    nix --extra-experimental-features 'nix-command flakes' run nixpkgs#openssh -- \
      ssh-keygen -t ed25519 -N "" -C "COMMENT" -f "$KEY" || echo "diag: nix run failed rc=$?"
  fi
else
  echo "diag: key already present"
fi

if [ -f "$KEY.pub" ]; then
  cat "$KEY.pub"
else
  echo "diag: $KEY.pub still missing"
fi
'@.Replace('COMMENT', $Comment)

  $out = @(Invoke-InDistro -DistroName $DistroName -Script $keyScript)
  $pubLine = $out | Where-Object { $_ -match '^ssh-' } | Select-Object -First 1

  if (-not $pubLine) {
    Write-Warn "Could not create or read a key. What the distro reported:"
    foreach ($line in $out) { Write-Warn "  $line" }
    return $null
  }
  return $pubLine.Trim()
}

function Test-GitHubSsh {
  <#
    GitHub exits 1 even on a successful auth check, so the exit code is useless --
    match the greeting instead. accept-new avoids an interactive host-key prompt on
    a connection that has no tty.
  #>
  param([Parameter(Mandatory)][string]$DistroName)
  $probe = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 || true"
  $out = (Invoke-InDistro -DistroName $DistroName -Script $probe) -join "`n"
  [pscustomobject]@{
    Authenticated = ($out -match 'successfully authenticated')
    Output        = $out.Trim()
  }
}

function Get-UpdateCloneScript {
  <#
    Brings a clone to exactly origin/main when that is safe, and refuses to touch it
    when it is not.

    A clean tree is reset hard rather than fast-forwarded: reset also repairs a
    diverged or detached checkout, where pull --ff-only just fails and leaves you
    building something old. A dirty tree is left alone -- uncommitted work outranks
    being current -- but the caller is told, loudly, which is the part that matters.
    Silently rebuilding a stale tree is the failure mode this exists to prevent.
  #>
  param([Parameter(Mandatory)][string]$RepoPath)
  @"
cd "$RepoPath" || { echo "UPDATE: no such directory: $RepoPath"; exit 1; }

# git is not in the NixOS-WSL base image -- same as openssh. It only arrives with the
# first rebuild, which is the very thing this function is trying to enable. Resolve a
# store path via nix-shell (channels, not flakes: the image has flakes off) and use it
# directly; the path stays valid after the shell exits.
GIT="`$(command -v git 2>/dev/null || true)"
if [ -z "`$GIT" ]; then
  GIT="`$(nix-shell -p git --run 'command -v git' 2>/dev/null | tail -1)"
fi
if [ -z "`$GIT" ] || [ ! -x "`$GIT" ]; then echo 'UPDATE: no git available'; exit 5; fi

if [ -n "`$("`$GIT" status --porcelain 2>/dev/null)" ]; then
  echo "UPDATE: local changes present, leaving the checkout alone"
  "`$GIT" log --oneline -1 2>/dev/null
  exit 2
fi
"`$GIT" fetch origin 2>&1 || { echo 'UPDATE: fetch failed'; "`$GIT" log --oneline -1; exit 3; }
"`$GIT" reset --hard origin/HEAD 2>/dev/null || "`$GIT" reset --hard origin/main 2>&1 || {
  echo 'UPDATE: reset failed'; "`$GIT" log --oneline -1; exit 4; }
echo "UPDATE: now at `$("`$GIT" rev-parse --short HEAD)"
"@
}

function Get-FlakeDefaultUser {
  <#
    Reads wsl.defaultUser out of the cloned flake, so the installer does not have to
    hardcode a username that lives in someone else's config. Returns $null if the
    flake cannot be evaluated -- caller falls back to leaving things where they are.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$RepoPath
  )
  $cmd = "cd '$RepoPath' 2>/dev/null && nix --extra-experimental-features 'nix-command flakes' " +
         "eval --raw .#nixosConfigurations.wsl.config.wsl.defaultUser 2>/dev/null"
  $u = (Invoke-InDistro -DistroName $DistroName -Script $cmd -User root) -join ""
  $u = $u.Trim()
  if ($script:LastDistroExitCode -ne 0 -or -not $u) { return $null }
  return $u
}

function Get-FirstRebuildCommand {
  <#
    Experimental features go on the command line because the imported image is
    channel-based and ships with flakes disabled -- the config enables them, but not
    until it has been applied once. Split out from the caller so the flag itself is
    testable; losing it is the single most likely way a clean install fails.

    -AsPath switches the flake reference from the default git+file:// to path:, which
    stops nix using libgit2 at all. That is the fallback when git refuses the repo for
    dubious ownership: the rebuild runs as root, the clone is owned by the image's
    default user, and libgit2 rejects the mismatch (error code 7).
  #>
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [switch]$AsPath
  )
  $ref = if ($AsPath) { "path:$RepoPath" } else { "'$RepoPath'" }
  "nixos-rebuild switch --flake $ref#wsl --option experimental-features 'nix-command flakes'"
}

function Invoke-FirstRebuild {
  <#
    Runs as root rather than via sudo. The fresh image has no password set, so sudo
    would prompt for one that does not exist; root needs none.

    Uses path: first, not git+file://. Running as root against a clone owned by the
    image's default user always trips libgit2's dubious-ownership check, and marking
    the repo safe in root's gitconfig does not persuade nix's bundled libgit2. So the
    git form fails on every clean install and prints an alarming error before the
    fallback rescues it. path: has no such problem.

    Only right for this one-shot. path: copies the directory into the store and keys
    on its whole content, so ordinary rebuilds should keep using the git form -- which
    they do, since they run as the owner and never hit the mismatch.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$RepoPath
  )
  Invoke-InDistro -DistroName $DistroName -User root `
    -Script "git config --global --add safe.directory '$RepoPath' 2>/dev/null; true" | Out-Null

  Invoke-InDistro -DistroName $DistroName -User root `
    -Script (Get-FirstRebuildCommand -RepoPath $RepoPath -AsPath) | Write-Host
  if ($script:LastDistroExitCode -eq 0) { return $true }

  Write-Warn "path: rebuild failed; retrying with a git flake reference."
  Invoke-InDistro -DistroName $DistroName -User root `
    -Script (Get-FirstRebuildCommand -RepoPath $RepoPath) | Write-Host
  return ($script:LastDistroExitCode -eq 0)
}

function Move-UserState {
  <#
    The clone and the SSH key are created as the image's default user (nixos), but the
    rebuild switches the default user to whoever the flake declares. Without this, both
    are stranded in /home/nixos and the new user comes up to an empty home -- no repo,
    no key, and a GitHub-registered key that appears not to work.
  #>
  param(
    [Parameter(Mandatory)][string]$DistroName,
    [Parameter(Mandatory)][string]$FromUser,
    [Parameter(Mandatory)][string]$ToUser,
    [Parameter(Mandatory)][string]$CloneTo
  )
  if ($FromUser -eq $ToUser) { return $true }

  $sh = @'
set -e
FROM=/home/FROMUSER
TO=/home/TOUSER
[ -d "$TO" ] || exit 0

if [ -d "$FROM/CLONEDIR" ] && [ ! -e "$TO/CLONEDIR" ]; then
  mv "$FROM/CLONEDIR" "$TO/CLONEDIR"
fi

if [ -d "$FROM/.ssh" ] && [ ! -e "$TO/.ssh" ]; then
  mv "$FROM/.ssh" "$TO/.ssh"
fi

chown -R TOUSER "$TO/CLONEDIR" 2>/dev/null || true
chown -R TOUSER "$TO/.ssh" 2>/dev/null || true
chmod 700 "$TO/.ssh" 2>/dev/null || true
chmod 600 "$TO/.ssh"/id_* 2>/dev/null || true
chmod 644 "$TO/.ssh"/*.pub 2>/dev/null || true
'@.Replace('FROMUSER', $FromUser).Replace('TOUSER', $ToUser).Replace('CLONEDIR', $CloneTo)

  Invoke-InDistro -DistroName $DistroName -Script $sh -User root | Out-Null
  return ($script:LastDistroExitCode -eq 0)
}

function Get-NextSteps {
  param([string]$DistroName, [string]$CloneTo)
  # Split out so a test can assert the steps stay in sync with the parameters.
  @"

$DistroName is installed.

What is left needs a human or a secret, so it is not scripted:

  1. Enter the distro. Open a NEW window -- the rebuild changed the default user,
     so any shell you already had open is still the old one.
       wsl -d $DistroName

  2. Git identity:
       git config --global user.name  "Your Name"
       git config --global user.email "your-email"

  3. Write the deny-list, then turn on the commit hook. It deliberately lives in no
     repo, so a fresh machine has none and the scan fails closed until you write it:
       mkdir -p ~/.config/devenv
       nano ~/.config/devenv/deny-list.txt
       git -C ~/$CloneTo config core.hooksPath githooks

  4. Authenticate the agent:
       claude

From here every rebuild is one line, no flags:
  sudo nixos-rebuild switch --flake ~/$CloneTo#wsl

If something goes wrong and you cannot sudo, root needs no password:
  wsl -d $DistroName -u root

"@
}

function Invoke-Main {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  # Makes wsl.exe emit UTF-8 rather than UTF-16LE, so its output is parseable.
  $env:WSL_UTF8 = "1"

  Write-Step "Checking WSL"
  $wslVersion = Get-WslVersion

  if ($DryRun) {
    Write-Host "    WSL version: $(if ($wslVersion) { $wslVersion } else { 'not present' })"
    Write-Step "Resolving the current NixOS-WSL release"
    $a = Resolve-NixosWslAsset
    Write-Host "    $($a.Tag) / $($a.Name) ($([math]::Round($a.Size / 1MB, 1)) MB)"
    Write-Host "    $($a.Url)"
    Write-Step "Dry run - stopping before any change"
    return
  }

  if ($null -eq $wslVersion) {
    if (-not (Test-Admin)) {
      throw "WSL is not installed and installing it needs Administrator. Re-run from an elevated PowerShell."
    }
    Write-Warn "WSL not found - installing it. This usually requires a reboot."
    & wsl.exe --install --no-distribution
    Write-Host ""
    Write-Host "WSL installed. Reboot, then run this script again." -ForegroundColor Green
    return
  }

  Write-Host "    WSL $wslVersion"
  if ($wslVersion -lt [version]"2.4.4") {
    Write-Warn "WSL $wslVersion is older than 2.4.4; using the legacy --import path."
    Write-Warn "Consider 'wsl --update' first - the newer path is less fragile."
  }

  # Idempotency is per phase, not for the script as a whole. An existing distribution
  # only means the *install* is done -- the key and the clone may still be outstanding,
  # and the documented flow (install WSL, reboot, re-run) lands here every time.
  $alreadyInstalled = (Get-InstalledDistros) -contains $DistroName
  if ($alreadyInstalled) {
    Write-Step "'$DistroName' is already registered - skipping install"
    Write-Host "    Start over with: wsl --unregister $DistroName   (destroys its filesystem)"
  }

  if (-not $alreadyInstalled) {
    if ($Tarball) {
      if (-not (Test-Path -LiteralPath $Tarball)) { throw "Not found: $Tarball" }
      $artifact = (Resolve-Path -LiteralPath $Tarball).Path
      Write-Step "Using supplied artifact: $artifact"
    } else {
      Write-Step "Finding the latest NixOS-WSL release"
      $asset = Resolve-NixosWslAsset
      Write-Host "    $($asset.Tag) / $($asset.Name) ($([math]::Round($asset.Size / 1MB, 1)) MB)"

      $artifact = Join-Path ([IO.Path]::GetTempPath()) $asset.Name
      Write-Step "Downloading to $artifact"
      $prev = $ProgressPreference
      $ProgressPreference = 'SilentlyContinue'   # the progress bar makes this ~10x slower
      try {
        Invoke-WebRequest -Uri $asset.Url -OutFile $artifact `
          -Headers @{ "User-Agent" = "devenv-installer" }
      } finally {
        $ProgressPreference = $prev
      }

      $actual = (Get-Item -LiteralPath $artifact).Length
      if ($actual -ne $asset.Size) {
        Remove-Item -LiteralPath $artifact -Force
        throw "Download is $actual bytes, expected $($asset.Size). Deleted it; re-run."
      }

      Write-Step "Verifying checksum"
      $hashOk = Test-ArtifactHash -Path $artifact -Sha256Url $asset.Sha256Url
      if ($hashOk -eq $false) {
        Remove-Item -LiteralPath $artifact -Force
        throw "SHA256 mismatch. Deleted the download; re-run."
      } elseif ($null -eq $hashOk) {
        Write-Warn "No published checksum for this release - size check only."
      } else {
        Write-Host "    sha256 ok"
      }
    }

    Write-Step "Installing '$DistroName' to $InstallPath"
    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

    if ($wslVersion -ge [version]"2.4.4") {
      & wsl.exe --install --from-file $artifact --name $DistroName --location $InstallPath
    } else {
      & wsl.exe --import $DistroName $InstallPath $artifact --version 2
    }
    if ($LASTEXITCODE -ne 0) { throw "Distribution install failed with exit code $LASTEXITCODE" }

    if (-not ((Get-InstalledDistros) -contains $DistroName)) {
      throw "Install reported success but '$DistroName' is not registered. Check 'wsl --list --verbose'."
    }
  }

  # SSH key. Generating it needs no credentials; only registering it does. Doing it
  # here means the clone below can use SSH, which is what makes a private repo work.
  $sshReady = $false
  if (-not $NoSshKey) {
    Write-Step "SSH key"

    # Reuse an existing Windows-side key if there is one. ssh-keygen output is random
    # every run -- the -C comment is only a label -- so a regenerated key is a *new*
    # key needing another GitHub registration. Persisting one keypair outside the
    # distro is what makes `wsl --unregister` and a reinstall cost nothing.
    $winKey = Get-WindowsSshKeyPath
    $haveDistroKey = $null -ne (Invoke-InDistro -DistroName $DistroName `
                       -Script 'test -f "$HOME/.ssh/id_ed25519" && echo yes')
    $haveDistroKey = $haveDistroKey -and $script:LastDistroExitCode -eq 0

    if (-not $FreshKey -and -not $haveDistroKey -and (Test-Path -LiteralPath $winKey)) {
      if (Copy-KeyIntoDistro -DistroName $DistroName -PrivatePath $winKey) {
        Write-Host "    reused the existing key from $winKey"
      } else {
        Write-Warn "Found $winKey but could not copy it in; generating a new one."
      }
    }

    $pub = New-SshKeyInDistro -DistroName $DistroName -Comment $Email
    if (-not $pub) {
      Write-Warn "Could not create or read a key. Skipping ahead; do it by hand."
    } else {
      if (-not (Test-Path -LiteralPath $winKey)) {
        # Convenience only -- never let a backup failure stop the install.
        if (Copy-KeyOutOfDistro -DistroName $DistroName -PrivatePath $winKey) {
          Write-Host "    saved a copy to $winKey so a reinstall can reuse it"
        } else {
          Write-Warn "Could not back the key up to $winKey - carrying on."
        }
      }
      Write-Host ""
      Write-Host $pub -ForegroundColor Green
      Write-Host ""
      Write-Host "Add that key at https://github.com/settings/ssh/new" -ForegroundColor Cyan

      $check = Test-GitHubSsh -DistroName $DistroName
      if ($check.Authenticated) {
        Write-Host "Already authenticated to GitHub." -ForegroundColor Green
        $sshReady = $true
      } elseif (-not $NonInteractive) {
        try { Start-Process "https://github.com/settings/ssh/new" | Out-Null } catch { }
        Read-Host "Press Enter once the key is added (or Ctrl-C to stop here)" | Out-Null
        $check = Test-GitHubSsh -DistroName $DistroName
        if ($check.Authenticated) {
          Write-Host "Authenticated." -ForegroundColor Green
          $sshReady = $true
        } else {
          Write-Warn "GitHub did not accept the key yet:"
          Write-Warn "  $($check.Output)"
          Write-Warn "Carry on and clone by hand once it works."
        }
      }
    }
  }

  if (-not $SkipClone) {
    Invoke-InDistro -DistroName $DistroName -Script "test -e ~/$CloneTo" | Out-Null
    if ($script:LastDistroExitCode -eq 0) {
      # Present is not the same as current. Skipping straight past an existing clone
      # meant a re-run rebuilt whatever was checked out last time, which is exactly
      # wrong for a script whose whole selling point is that re-running is safe.
      # As the owning user, not root -- git rejects a repo owned by someone else.
      Write-Step "~/$CloneTo already present - bringing it to origin"
      $upOut = @(Invoke-InDistro -DistroName $DistroName `
                   -Script (Get-UpdateCloneScript -RepoPath "`$HOME/$CloneTo"))
      foreach ($l in $upOut) { Write-Host "    $l" }
      if ($script:LastDistroExitCode -eq 2) {
        Write-Warn "The rebuild below will use your local state, not origin."
      } elseif ($script:LastDistroExitCode -ne 0) {
        Write-Warn "Could not update the clone. The rebuild will use whatever is checked out."
      }
    } else {
      # Prefer SSH when the key is live -- the only form that works for a private repo.
      $url = if ($sshReady) { ConvertTo-SshUrl -Url $RepoUrl } else { $RepoUrl }
      Write-Step "Cloning $url into ~/$CloneTo"
      $cloneCmd = "nix --extra-experimental-features 'nix-command flakes' run nixpkgs#git -- clone $url ~/$CloneTo"
      Invoke-InDistro -DistroName $DistroName -Script $cloneCmd | Write-Host
      if ($script:LastDistroExitCode -ne 0) {
        Write-Warn "Clone failed (exit $LASTEXITCODE). The distribution itself is fine."
        if (-not $sshReady) {
          Write-Warn "If that repo is private, an anonymous HTTPS clone cannot work - add the key, then:"
          Write-Warn "  git clone $(ConvertTo-SshUrl -Url $RepoUrl) ~/$CloneTo"
        }
      }
    }
  }

  # Everything below needs the repo on disk.
  #
  # whoami, not `echo $USER`: USER is frequently unset in a non-interactive WSL shell,
  # which silently produced "/home//devenv", failed the directory test, and skipped the
  # rebuild without saying a word.
  $currentUser = ((Invoke-InDistro -DistroName $DistroName -Script 'whoami') -join "").Trim()
  if (-not $currentUser) {
    Write-Warn "Could not determine the distro user; assuming 'nixos'."
    $currentUser = 'nixos'
  }
  $repoPath = "/home/$currentUser/$CloneTo"
  $repoPresent = $false
  Invoke-InDistro -DistroName $DistroName -Script "test -d '$repoPath'" | Out-Null
  if ($script:LastDistroExitCode -eq 0) { $repoPresent = $true }
  $headLine = if ($repoPresent) {
    ((Invoke-InDistro -DistroName $DistroName -Script "G=\$(command -v git || nix-shell -p git --run 'command -v git' 2>/dev/null | tail -1); \"\$G\" -C '$repoPath' log --oneline -1 2>/dev/null") -join " ").Trim()
  } else { "n/a" }
  Write-Host "    user=$currentUser repo=$repoPath present=$repoPresent"
  Write-Host "    head=$headLine"

  if ($SkipRebuild) {
    Write-Step "Skipping the first rebuild (-SkipRebuild). Run it yourself with:"
    Write-Host "      wsl -d $DistroName -u root -- $(Get-FirstRebuildCommand -RepoPath $repoPath)"
  } elseif (-not $repoPresent) {
    # Never skip this quietly -- an install that stops here looks finished but is not.
    Write-Warn "No repo at $repoPath, so the first rebuild was not run."
    Write-Warn "Find the clone and rebuild against it:"
    Write-Warn "  wsl -d $DistroName -- bash -lc 'ls -d ~/$CloneTo'"
  }

  if (-not $SkipRebuild -and $repoPresent) {
    $targetUser = Get-FlakeDefaultUser -DistroName $DistroName -RepoPath $repoPath
    if (-not $targetUser) { $targetUser = $currentUser }

    Write-Step "First rebuild (as root, so no password is needed) - this takes a while"
    if (Invoke-FirstRebuild -DistroName $DistroName -RepoPath $repoPath) {
      Write-Host "    rebuild ok" -ForegroundColor Green

      if ($targetUser -ne $currentUser) {
        Write-Step "Moving the repo and SSH key into /home/$targetUser"
        if (Move-UserState -DistroName $DistroName -FromUser $currentUser `
                           -ToUser $targetUser -CloneTo $CloneTo) {
          Write-Host "    moved" -ForegroundColor Green
        } else {
          Write-Warn "Move failed. The repo and key are still in /home/$currentUser."
          Write-Warn "  wsl -d $DistroName -u root -- mv /home/$currentUser/$CloneTo /home/$targetUser/"
        }
      }
    } else {
      Write-Warn "Rebuild failed. Nothing was moved; the distribution is otherwise fine."
      Write-Warn "Run it by hand to see the error:"
      Write-Warn "  wsl -d $DistroName -u root -- nixos-rebuild switch --flake $repoPath#wsl --option experimental-features 'nix-command flakes'"
    }
  }

  Write-Host (Get-NextSteps -DistroName $DistroName -CloneTo $CloneTo) -ForegroundColor Cyan
}

# Dot-sourcing sets InvocationName to '.', which loads the functions without running
# them. The env var is a belt-and-braces override for the test harness: if the
# InvocationName check ever misbehaves, the fallback is running a real installer on a
# CI machine, so it is worth having two independent guards rather than one clever one.
if (-not $env:DEVENV_INSTALLER_NORUN -and $MyInvocation.InvocationName -ne '.') {
  Invoke-Main
}
