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

Describe 'ConvertTo-Base64Script' {
  It 'round-trips a multi-line script' {
    $s = "set -e`nKEY=`"`$HOME/.ssh/id_ed25519`"`ncat `"`$KEY.pub`""
    $b = ConvertTo-Base64Script -Script $s
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | Should -Be $s
  }

  It 'emits nothing a shell would treat as syntax' {
    # The whole point: no newlines, no quotes, no dollar signs to survive two shells.
    $b = ConvertTo-Base64Script -Script "echo `$HOME`ncat 'x y'`n"
    $b | Should -Not -Match "[`n`r'`"$]"
  }
}

Describe 'Get-DecodeCommand' {
  It 'is a single line' {
    (Get-DecodeCommand -Base64 'YWJj') -split "`n" | Should -HaveCount 1
  }

  It 'pipes through base64 -d into a login shell' {
    Get-DecodeCommand -Base64 'YWJj' | Should -Be "echo 'YWJj' | base64 -d | bash -l"
  }
}

Describe 'Get-WindowsSshKeyPath' {
  It 'points at the conventional OpenSSH location' {
    Get-WindowsSshKeyPath -Home_ 'C:\Users\someone' | Should -Be 'C:\Users\someone\.ssh\id_ed25519'
  }

  It 'names the private half, not the public one' {
    # The .pub is derived by appending; getting this backwards would copy the wrong file.
    Get-WindowsSshKeyPath -Home_ 'C:\x' | Should -Not -Match '\.pub$'
  }
}

Describe 'Test-Base64String' {
  It 'accepts well-formed base64' {
    Test-Base64String 'YWJjZA==' | Should -BeTrue
  }

  It 'rejects the empty string and null' {
    Test-Base64String '' | Should -BeFalse
    Test-Base64String $null | Should -BeFalse
  }

  It 'rejects a shell banner or error text' {
    # The real failure: something non-base64 reached FromBase64String, which throws
    # instead of returning null, and took the whole install down with it.
    Test-Base64String 'base64: /home/x/.ssh/id_ed25519: No such file' | Should -BeFalse
  }

  It 'rejects a length that is not a multiple of four' {
    Test-Base64String 'YWJjZA=' | Should -BeFalse
  }

  It 'rejects characters outside the alphabet' {
    Test-Base64String 'YWJj ZA==' | Should -BeFalse
  }
}

Describe 'Select-AfterMarker' {
  It 'drops everything before the marker' {
    # The real case: a NixOS-WSL welcome banner printed by a login profile, followed
    # by the output we actually asked for.
    $lines = @('Welcome to your new NixOS-WSL system!', 'Please run sudo nixos-rebuild',
               '@@M@@', 'nixos')
    Select-AfterMarker -Lines $lines -Marker '@@M@@' | Should -Be @('nixos')
  }

  It 'uses the last marker when the banner repeats' {
    $lines = @('banner', '@@M@@', 'banner again', '@@M@@', 'real')
    Select-AfterMarker -Lines $lines -Marker '@@M@@' | Should -Be @('real')
  }

  It 'returns empty when the marker is the final line' {
    # A command that produced no output at all -- exit code is what matters there.
    $r = Select-AfterMarker -Lines @('noise', '@@M@@') -Marker '@@M@@'
    $r.Count | Should -Be 0
  }

  It 'passes everything through when the marker is absent' {
    Select-AfterMarker -Lines @('a', 'b') -Marker '@@M@@' | Should -Be @('a', 'b')
  }

  It 'returns an array, not null, for empty input' {
    $r = Select-AfterMarker -Lines @() -Marker '@@M@@'
    $r -is [array] | Should -BeTrue
  }

  It 'keeps multi-line output intact' {
    Select-AfterMarker -Lines @('x', '@@M@@', 'l1', 'l2', 'l3') -Marker '@@M@@' |
      Should -Be @('l1', 'l2', 'l3')
  }
}

Describe 'Get-FirstRebuildCommand -AsPath' {
  It 'uses a path: reference that bypasses git' {
    # Fallback for libgit2 refusing a repo owned by another user (error code 7).
    Get-FirstRebuildCommand -RepoPath '/home/nixos/devenv' -AsPath |
      Should -Match '--flake path:/home/nixos/devenv#wsl'
  }

  It 'still passes experimental features in the fallback' {
    Get-FirstRebuildCommand -RepoPath '/x' -AsPath |
      Should -Match "experimental-features 'nix-command flakes'"
  }

  It 'differs from the default form' {
    (Get-FirstRebuildCommand -RepoPath '/x') |
      Should -Not -Be (Get-FirstRebuildCommand -RepoPath '/x' -AsPath)
  }
}

Describe 'Get-UpdateCloneScript' {
  BeforeAll { $script:s = Get-UpdateCloneScript -RepoPath '/home/nixos/devenv' }

  It 'cds to the repo it was given' {
    $script:s | Should -BeLike '*cd "/home/nixos/devenv"*'
  }

  It 'resets hard rather than fast-forwarding' {
    # reset also repairs a diverged or detached checkout; pull --ff-only just fails
    # and leaves you rebuilding something old.
    $script:s | Should -Match 'git reset --hard origin/'
  }

  It 'checks for local changes before touching anything' {
    $script:s | Should -Match 'git status --porcelain'
  }

  It 'reports the resulting commit' {
    $script:s | Should -Match 'git rev-parse --short HEAD'
  }

  It 'uses distinct exit codes so the caller can tell cases apart' {
    foreach ($code in 1..4) { $script:s | Should -Match "exit $code" }
  }
}

Describe 'Get-UpdateCloneScript quoting' {
  It 'double-quotes the path so the shell expands it' {
    # Single quotes meant `cd '$HOME/devenv'` never expanded, so the update always
    # reported "no such directory" and the rebuild silently used a stale tree.
    # -BeLike, not -Match: a Windows path is full of regex metacharacters.
    $s = Get-UpdateCloneScript -RepoPath 'PLACEHOLDER/devenv'
    $s | Should -BeLike '*cd "PLACEHOLDER/devenv"*'
    $s | Should -Not -BeLike "*cd 'PLACEHOLDER/devenv'*"
  }

  It 'names the path it could not enter' {
    $s = Get-UpdateCloneScript -RepoPath 'PLACEHOLDER/devenv'
    $s | Should -BeLike '*no such directory: PLACEHOLDER/devenv*'
  }
}
