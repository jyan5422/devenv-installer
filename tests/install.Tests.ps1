BeforeAll {
  . (Join-Path $PSScriptRoot '..' 'install.ps1')
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

  It 'is one of the two names we know about' {
    # Fails loudly the day upstream renames it again, which is the point.
    $script:asset.Name | Should -BeIn @('nixos.wsl', 'nixos-wsl.tar.gz')
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
    $s = Get-NextSteps -DistroName 'MyDistro' -CloneTo 'myconfig' -RepoUrl 'https://example.com/r.git'
    $s | Should -Match 'wsl -d MyDistro'
    $s | Should -Match '~/myconfig#wsl'
    $s | Should -Match 'https://example\.com/r\.git'
  }

  It 'passes experimental features on the first rebuild' {
    # The single most likely first-run failure, so assert the workaround is present.
    $s = Get-NextSteps -DistroName 'NixOS' -CloneTo 'devenv' -RepoUrl 'x'
    $s | Should -Match "experimental-features 'nix-command flakes'"
  }
}

Describe 'Get-InstalledDistros' {
  It 'returns an array even where WSL is absent' {
    # CI runners have no WSL; the function must degrade to empty, not throw.
    $d = Get-InstalledDistros
    ,$d | Should -BeOfType [System.Object[]]
  }
}
