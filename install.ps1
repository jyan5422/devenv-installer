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
  try { $raw = & wsl.exe --list --quiet 2>$null } catch { return @() }
  if (-not $raw) { return @() }
  @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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

  # openssh may not be in the base image; fall back to running it from nixpkgs.
  $keyScript = @'
set -e
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -t ed25519 -N "" -C "COMMENT" -f "$KEY" >/dev/null
  else
    nix --extra-experimental-features 'nix-command flakes' \
      run nixpkgs#openssh -- ssh-keygen -t ed25519 -N "" -C "COMMENT" -f "$KEY" >/dev/null
  fi
fi
cat "$KEY.pub"
'@.Replace('COMMENT', $Comment)

  $pub = & wsl.exe -d $DistroName -- bash -lc $keyScript
  if ($LASTEXITCODE -ne 0) { return $null }
  ($pub -join "`n").Trim()
}

function Test-GitHubSsh {
  <#
    GitHub exits 1 even on a successful auth check, so the exit code is useless --
    match the greeting instead. accept-new avoids an interactive host-key prompt on
    a connection that has no tty.
  #>
  param([Parameter(Mandatory)][string]$DistroName)
  $probe = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 || true"
  $out = (& wsl.exe -d $DistroName -- bash -lc $probe) -join "`n"
  [pscustomobject]@{
    Authenticated = ($out -match 'successfully authenticated')
    Output        = $out.Trim()
  }
}

function Get-NextSteps {
  param([string]$DistroName, [string]$CloneTo, [string]$RepoUrl)
  # Split out so a test can assert the steps stay in sync with the parameters.
  @"

$DistroName is installed.

The rest needs credentials or a human, so it is not scripted:

  1. Enter the distro:
       wsl -d $DistroName

  2. Set a password (sudo needs one):
       passwd

  3. Git identity:
       git config --global user.name  "Your Name"
       git config --global user.email "your-email"

  4. Clone your config repo, if the installer could not:
       nix --extra-experimental-features 'nix-command flakes' \
         run nixpkgs#git -- clone $RepoUrl ~/$CloneTo

  5. First rebuild. Flakes go on the command line this once, because the imported
     image is channel-based and has them disabled:
       sudo nixos-rebuild switch --flake ~/$CloneTo#wsl \
         --option experimental-features 'nix-command flakes'

     Afterwards it is just:
       sudo nixos-rebuild switch --flake ~/$CloneTo#wsl

     Then close the shell and reopen it -- the default user changes.

  6. Anything repo-specific -- commit hooks, scan configuration, agent auth --
     is in that repo's README. Read it before your first commit.

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

  if ((Get-InstalledDistros) -contains $DistroName) {
    Write-Host ""
    Write-Host "A distribution named '$DistroName' already exists - nothing to do." -ForegroundColor Green
    Write-Host "  Enter it:    wsl -d $DistroName"
    Write-Host "  Start over:  wsl --unregister $DistroName   (destroys its filesystem)"
    return
  }

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

  # SSH key. Generating it needs no credentials; only registering it does. Doing it
  # here means the clone below can use SSH, which is what makes a private repo work.
  $sshReady = $false
  if (-not $NoSshKey) {
    Write-Step "SSH key"
    $pub = New-SshKeyInDistro -DistroName $DistroName -Comment $Email
    if (-not $pub) {
      Write-Warn "Could not create or read a key. Skipping ahead; do it by hand."
    } else {
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
    # Prefer SSH when the key is live -- it is the only form that works for a private repo.
    $url = if ($sshReady) { ConvertTo-SshUrl -Url $RepoUrl } else { $RepoUrl }
    Write-Step "Cloning $url into ~/$CloneTo"
    $cloneCmd = "nix --extra-experimental-features 'nix-command flakes' run nixpkgs#git -- clone $url ~/$CloneTo"
    & wsl.exe -d $DistroName -- bash -lc $cloneCmd
    if ($LASTEXITCODE -ne 0) {
      Write-Warn "Clone failed (exit $LASTEXITCODE). The distribution itself is fine."
      if (-not $sshReady) {
        Write-Warn "If that repo is private, an anonymous HTTPS clone cannot work - add the key, then:"
        Write-Warn "  git clone $(ConvertTo-SshUrl -Url $RepoUrl) ~/$CloneTo"
      }
    }
  }

  Write-Host (Get-NextSteps -DistroName $DistroName -CloneTo $CloneTo -RepoUrl $RepoUrl) -ForegroundColor Cyan
}

# Dot-sourcing sets InvocationName to '.', which loads the functions without running
# them. The env var is a belt-and-braces override for the test harness: if the
# InvocationName check ever misbehaves, the fallback is running a real installer on a
# CI machine, so it is worth having two independent guards rather than one clever one.
if (-not $env:DEVENV_INSTALLER_NORUN -and $MyInvocation.InvocationName -ne '.') {
  Invoke-Main
}
