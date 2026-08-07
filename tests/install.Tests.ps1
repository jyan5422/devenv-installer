BeforeAll {
  # Guard first: dot-sourcing must load the functions without running the installer.
  # If that ever breaks, the failure mode is a real install attempt on the runner.
  $env:DEVENV_INSTALLER_NORUN = '1'
  . (Join-Path $PSScriptRoot '..' 'install.ps1')

  # install.ps1 sets ErrorActionPreference at script scope, which dot-sourcing leaks
  # into the test session. Put it back so a stray non-terminating error in a test
  # does not abort the run.
  $ErrorActionPreference = 'Continue'
}

AfterAll {
  Remove-Item Env:\DEVENV_INSTALLER_NORUN -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-WslVersion' {
  It 'parses a standard four-part banner down to three parts' {
    ConvertTo-WslVersion -Raw "WSL version: 2.4.13.0" | Should -Be ([version]'2.4.13')
  }

  It 'finds the version among the other banner lines' {
    $raw = @"
WSL version: 2.5.10.0
Kernel version: 6.6.87.2-1
WSLg version: 1.0.66
Windows version: 10.0.26100.4061
"@
    ConvertTo-WslVersion -Raw $raw | Should -Be ([version]'2.5.10')
  }

  It 'returns null for empty input' {
    ConvertTo-WslVersion -Raw "" | Should -BeNullOrEmpty
  }

  It 'returns null when the banner is absent' {
    # What the legacy in-Windows WSL prints -- it has no --version at all.
    ConvertTo-WslVersion -Raw "Invalid command line option: --version" | Should -BeNullOrEmpty
  }

  It 'compares correctly against the 2.4.4 floor' {
    (ConvertTo-WslVersion -Raw "WSL version: 2.4.3.0") -lt [version]'2.4.4' | Should -BeTrue
    (ConvertTo-WslVersion -Raw "WSL version: 2.4.4.0") -ge [version]'2.4.4' | Should -BeTrue
    (ConvertTo-WslVersion -Raw "WSL version: 2.10.0.0") -ge [version]'2.4.4' | Should -BeTrue
  }
}

Describe 'Resolve-NixosWslAsset' -Tag 'Network' {
  BeforeAll { $script:asset = Resolve-NixosWslAsset }

  It 'finds an artifact in the current release' {
    $script:asset | Should -Not -BeNullOrEmpty
  }

  It 'is one of the names we know about' {
    # Fails loudly the day upstream renames it again, which is the point.
    $script:asset.Name | Should -BeIn @('nixos.wsl', 'nixos.aarch64.wsl', 'nixos-wsl.tar.gz')
  }

  It 'finds the matching published checksum' {
    $script:asset.Sha256Url | Should -Match '\.sha256$'
  }

  It 'reports a plausible size' {
    $script:asset.Size | Should -BeGreaterThan 100MB
  }

  It 'points at a github download URL' {
    $script:asset.Url | Should -Match '^https://github\.com/nix-community/NixOS-WSL/releases/download/'
  }
}

Describe 'ConvertTo-SshUrl' {
  It 'converts an https github url with .git' {
    ConvertTo-SshUrl -Url 'https://github.com/owner/repo.git' |
      Should -Be 'git@github.com:owner/repo.git'
  }

  It 'converts an https github url without .git' {
    ConvertTo-SshUrl -Url 'https://github.com/owner/repo' |
      Should -Be 'git@github.com:owner/repo.git'
  }

  It 'tolerates a trailing slash' {
    ConvertTo-SshUrl -Url 'https://github.com/owner/repo/' |
      Should -Be 'git@github.com:owner/repo.git'
  }

  It 'handles hyphens and dots in the repo name' {
    ConvertTo-SshUrl -Url 'https://github.com/jyan5422/devenv-installer.git' |
      Should -Be 'git@github.com:jyan5422/devenv-installer.git'
  }

  It 'leaves an ssh url alone' {
    ConvertTo-SshUrl -Url 'git@github.com:owner/repo.git' |
      Should -Be 'git@github.com:owner/repo.git'
  }

  It 'leaves a non-github url alone' {
    ConvertTo-SshUrl -Url 'https://gitlab.com/owner/repo.git' |
      Should -Be 'https://gitlab.com/owner/repo.git'
  }

  It 'does not mangle a deep url it cannot parse' {
    # Two path segments only; anything else passes through rather than guessing.
    ConvertTo-SshUrl -Url 'https://github.com/owner/repo/tree/main' |
      Should -Be 'https://github.com/owner/repo/tree/main'
  }
}

Describe 'Get-NextSteps' {
  It 'substitutes the distro name and clone target' {
    $s = Get-NextSteps -DistroName 'MyDistro' -CloneTo 'myconfig'
    $s | Should -Match 'wsl -d MyDistro'
    $s | Should -Match '~/myconfig#wsl'
  }

  It 'tells you to open a new window' {
    # The rebuild changes the default user, so an already-open shell is stale. Easy
    # to skip past, and everything afterwards looks subtly wrong if you do.
    $s = Get-NextSteps -DistroName 'NixOS' -CloneTo 'devenv'
    $s | Should -Match 'NEW window'
  }

  It 'no longer tells you to pass experimental features' {
    # The installer runs the first rebuild itself now. Leaving the flag in the printed
    # steps would have people typing it forever on rebuilds that do not need it.
    $s = Get-NextSteps -DistroName 'NixOS' -CloneTo 'devenv'
    $s | Should -Not -Match "experimental-features"
  }

  It 'points at root as the recovery path' {
    $s = Get-NextSteps -DistroName 'NixOS' -CloneTo 'devenv'
    $s | Should -Match '-u root'
  }
}

Describe 'Get-FirstRebuildCommand' {
  It 'passes experimental features' {
    # The single most likely way a clean install fails: the imported image is
    # channel-based and has flakes off until this rebuild enables them.
    Get-FirstRebuildCommand -RepoPath '/home/nixos/devenv' |
      Should -Match "--option experimental-features 'nix-command flakes'"
  }

  It 'targets the wsl output of the flake at the given path' {
    Get-FirstRebuildCommand -RepoPath '/home/nixos/devenv' |
      Should -Match "--flake '/home/nixos/devenv'#wsl"
  }

  It 'does not invoke sudo' {
    # It runs as root; a sudo here would prompt for a password that does not exist yet.
    Get-FirstRebuildCommand -RepoPath '/x' | Should -Not -Match 'sudo'
  }
}

Describe 'Get-InstalledDistros' {
  It 'does not throw where WSL is absent' {
    # CI runners have no WSL; the function must degrade, not blow up.
    { Get-InstalledDistros } | Should -Not -Throw
  }

  It 'returns an array, not null, when there are no distros' {
    # The bug this caught: `return @()` unrolls to nothing on output, so the caller
    # gets $null. Only `,@()` survives. Checked without the pipeline, because piping
    # an empty array sends zero objects to Should and fails for the wrong reason.
    # -BeNullOrEmpty is no good here: an empty array is the correct answer and would
    # trip it. `-is [array]` distinguishes @() from $null, which is the actual contract.
    $d = Get-InstalledDistros
    $d -is [array] | Should -BeTrue -Because '$null would mean the empty-array return unrolled away'
  }
}

Describe 'Get-TargetArchName' {
  It 'picks the x86_64 artifact by default' {
    Get-TargetArchName -Arch 'AMD64' | Should -Be 'nixos.wsl'
  }

  It 'picks the aarch64 artifact on ARM' {
    Get-TargetArchName -Arch 'ARM64' | Should -Be 'nixos.aarch64.wsl'
  }

  It 'does not confuse the two names' {
    # nixos.aarch64.wsl would match a sloppy wildcard for nixos.wsl.
    Get-TargetArchName -Arch 'AMD64' | Should -Not -Be 'nixos.aarch64.wsl'
  }
}

Describe 'Test-ArtifactHash' {
  It 'returns null when there is no published checksum' {
    # Null, not true -- a missing checksum must not read as a passing check.
    Test-ArtifactHash -Path $PSCommandPath -Sha256Url $null | Should -BeNullOrEmpty
  }
}
