#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the dependencies listed in nvim/installables.md.

.DESCRIPTION
    Shows a checkbox menu of every installable dependency, then installs only
    the ticked ones. winget packages go through 'winget install' (already-
    installed packages are skipped by winget itself). Spring Boot CLI is not on
    winget, so it is downloaded from Maven Central into
    %LOCALAPPDATA%\Programs\spring-boot-cli and its bin is added to the user PATH.

    After each install the script prints where the package lives on disk, and
    repeats every path in the summary.

    Menu keys: Up/Down (or k/j) move, Space toggle, A all/none, N nvim deps only,
    Enter install, Esc/Q quit.

    Items that are NOT installable here are printed as manual steps at the end:
      - 0xProto Font      (download from GitHub)
      - Aseprite          (paid, download from aseprite.org)
      - Flutter           (dart pub global activate flutter / flutter.dev)
      - FVM               (dart pub global activate fvm)
      - vcpkg             (git clone)
      - Pi Agent Harness  (scripts\build-pi.ps1)

    Safe to re-run; every installer is idempotent.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-deps.ps1

.EXAMPLE
    # Open the menu with only the nvim plugin dependencies ticked
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-deps.ps1 -NvimOnly

.EXAMPLE
    # No menu: install specific items by name or winget id (wildcards ok)
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-deps.ps1 -Only "Spring Boot CLI","Neovim*"
#>

param(
    # Pre-tick only what the nvim plugins need (instead of everything).
    [switch]$NvimOnly,
    # Skip the menu and install the pre-ticked set.
    [switch]$All,
    # Skip the menu and install items whose name or id matches (wildcards ok).
    [string[]]$Only
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"   # Invoke-WebRequest is very slow with the progress bar in 5.1

# ---------------------------------------------------------------------------
# Package list, mirroring nvim/installables.md
#   Cmd   - executable looked up on PATH to report the install path
#   Paths - known install locations (wildcards ok), checked before Cmd
# ---------------------------------------------------------------------------
function Pkg([string]$Name, [string]$Id, [string]$Group, [string]$Cmd, [string[]]$Paths = @(), [string]$Kind = "winget") {
    [pscustomobject]@{ Name = $Name; Id = $Id; Group = $Group; Cmd = $Cmd; Paths = $Paths; Kind = $Kind; Selected = $false }
}

$pf   = $env:ProgramFiles
$pf86 = ${env:ProgramFiles(x86)}
$lad  = $env:LOCALAPPDATA

$items = @(
    # General dev tools
    (Pkg "nvm-windows"         "CoreyButler.NVMforWindows"         general "nvm")
    # Node.js is installed via nvm (see manual steps), not winget.
    (Pkg "pnpm"                "pnpm.pnpm"                         general "pnpm")
    (Pkg "Python 3.13"         "Python.Python.3.13"                general "python" @("$lad\Programs\Python\Python313\python.exe", "$pf\Python313\python.exe"))
    (Pkg "Obsidian"            "Obsidian.Obsidian"                 general $null    @("$lad\Programs\Obsidian\Obsidian.exe", "$pf\Obsidian\Obsidian.exe"))
    (Pkg "Bruno"               "Bruno.Bruno"                       general $null    @("$lad\Programs\bruno\Bruno.exe", "$pf\Bruno\Bruno.exe"))
    (Pkg "MongoDB"             "MongoDB.Server"                    general "mongod" @("$pf\MongoDB\Server\*\bin\mongod.exe"))
    (Pkg "PostgreSQL 17"       "PostgreSQL.PostgreSQL.17"          general "psql"   @("$pf\PostgreSQL\17\bin\psql.exe"))
    (Pkg "Docker Desktop"      "Docker.DockerDesktop"              general "docker" @("$pf\Docker\Docker\Docker Desktop.exe"))
    (Pkg "VS Build Tools 2026" "Microsoft.VisualStudio.BuildTools" general $null    @("$pf\Microsoft Visual Studio\*\BuildTools", "$pf86\Microsoft Visual Studio\*\BuildTools"))
    (Pkg "LLVM"                "LLVM.LLVM"                         general "clang"  @("$pf\LLVM\bin\clang.exe"))
    (Pkg "Dart SDK"            "Google.DartSDK"                    general "dart")
    (Pkg "Neovim"              "Neovim.Neovim"                     general "nvim")
    (Pkg "Crush"               "charmbracelet.crush"               general "crush")
    (Pkg "Bun"                 "Oven-sh.Bun"                       general "bun")   # required by build-pi.ps1 (binary build)
    (Pkg "CMake"               "Kitware.CMake"                     general "cmake")
    (Pkg "Spring Boot CLI"     "spring-boot-cli"                   general "spring" @() "springboot")   # Maven Central, needs JDK 17+
    # LSP (mason-lspconfig)
    (Pkg "Go"                  "GoLang.Go"                         nvim "go")        # gopls
    (Pkg "Rustup"              "Rustlang.Rustup"                   nvim "rustup")    # rust_analyzer
    (Pkg "Terraform"           "Hashicorp.Terraform"               nvim "terraform") # terraformls
    (Pkg "Temurin JDK 21"      "EclipseAdoptium.Temurin.21.JDK"    nvim "java" @("$pf\Eclipse Adoptium\jdk-21*\bin\java.exe"))  # runs jdtls; needs JDK 21+
    # Telescope
    (Pkg "ripgrep"             "BurntSushi.ripgrep.MSVC"           nvim "rg")        # live_grep
    (Pkg "fd"                  "sharkdp.fd"                        nvim "fd")        # find_files performance
    # Formatting (mason-tool-installer)
    (Pkg "StyLua"              "JohnnyMorganz.StyLua"              nvim "stylua")
    # Python plugin (uv.nvim)
    (Pkg "uv"                  "astral-sh.uv"                      nvim "uv")
    # Git plugins
    (Pkg "Git"                 "Git.Git"                           nvim "git")
    (Pkg "GitHub CLI"          "GitHub.cli"                        nvim "gh")        # optional
)

# Extra installer arguments for packages whose defaults don't fit.
$overrides = @{
    # Temurin's MSI leaves JAVA_HOME unset by default; java.lua prefers $JAVA_HOME/bin/java.
    "EclipseAdoptium.Temurin.21.JDK" = "ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLLEVEL=1 /quiet"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Resolve-InstallPath($item) {
    foreach ($p in $item.Paths) {
        $hit = Get-Item -Path $p -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
        if ($hit) { return $hit.FullName }
    }
    if ($item.Cmd) {
        $cmd = Get-Command $item.Cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Show-Checklist($items) {
    $cursor = 0
    $top    = 0
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $height = [Math]::Max(5, [Console]::WindowHeight - 7)
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $height) { $top = $cursor - $height + 1 }
            $end = [Math]::Min($items.Count, $top + $height) - 1

            Clear-Host
            Write-Host "Select what to install" -ForegroundColor Cyan
            Write-Host "  Up/Down move   Space toggle   A all/none   N nvim deps only   Enter install   Esc quit" -ForegroundColor DarkGray
            Write-Host ""
            for ($i = $top; $i -le $end; $i++) {
                $it   = $items[$i]
                $box  = if ($it.Selected) { "[x]" } else { "[ ]" }
                $mark = if ($i -eq $cursor) { ">" } else { " " }
                $line = "{0} {1} {2,-22} {3,-8} {4}" -f $mark, $box, $it.Name, $it.Group, $it.Id
                if ($i -eq $cursor)  { Write-Host $line -ForegroundColor Black -BackgroundColor Gray }
                elseif ($it.Selected) { Write-Host $line -ForegroundColor Green }
                else                  { Write-Host $line }
            }
            $count  = @($items | Where-Object Selected).Count
            $scroll = if ($items.Count -gt $height) { "   (showing $($top + 1)-$($end + 1))" } else { "" }
            Write-Host ""
            Write-Host "  $count of $($items.Count) selected$scroll" -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                { $_ -in "UpArrow", "K" }   { $cursor = ($cursor - 1 + $items.Count) % $items.Count }
                { $_ -in "DownArrow", "J" } { $cursor = ($cursor + 1) % $items.Count }
                "Home"     { $cursor = 0 }
                "End"      { $cursor = $items.Count - 1 }
                "PageUp"   { $cursor = [Math]::Max(0, $cursor - $height) }
                "PageDown" { $cursor = [Math]::Min($items.Count - 1, $cursor + $height) }
                "Spacebar" { $items[$cursor].Selected = -not $items[$cursor].Selected }
                "A" {
                    $on = $count -lt $items.Count
                    $items | ForEach-Object { $_.Selected = $on }
                }
                "N" { $items | ForEach-Object { $_.Selected = ($_.Group -eq "nvim") } }
                "Enter" { return $true }
                { $_ -in "Escape", "Q" } { return $false }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
        Clear-Host
    }
}

function Install-Winget($item) {
    $extra = if ($overrides.ContainsKey($item.Id)) { @("--override", $overrides[$item.Id]) } else { @() }
    winget install --id $item.Id --exact --accept-source-agreements --accept-package-agreements --disable-interactivity @extra
    # 0 = installed; -1978335189 (0x8A15002B) = already installed / no applicable update
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) { return $true }
    Write-Host "winget exit code $LASTEXITCODE" -ForegroundColor Red
    return $false
}

function Install-SpringBootCli {
    $root = "$env:LOCALAPPDATA\Programs\spring-boot-cli"
    $repo = "https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $meta = [xml](Invoke-WebRequest -UseBasicParsing "$repo/maven-metadata.xml").Content
        # Latest GA release (metadata's <release> can be a milestone)
        $ver = @($meta.metadata.versioning.versions.version |
                 Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
                 Sort-Object { [version]$_ })[-1]
        $springHome = "$root\spring-$ver"

        if (Test-Path "$springHome\bin\spring.bat") {
            Write-Host "Spring Boot CLI $ver already installed"
        } else {
            $zip = Join-Path $env:TEMP "spring-boot-cli-$ver-bin.zip"
            Write-Host "Downloading Spring Boot CLI $ver"
            Invoke-WebRequest -UseBasicParsing "$repo/$ver/spring-boot-cli-$ver-bin.zip" -OutFile $zip
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            Expand-Archive -Path $zip -DestinationPath $root -Force
            Remove-Item $zip
            if (-not (Test-Path "$springHome\bin\spring.bat")) { throw "unexpected archive layout: $springHome\bin\spring.bat missing" }
        }

        # Put this version's bin on the user PATH, dropping older spring-boot-cli entries.
        # Edited through the registry to keep REG_EXPAND_SZ (%VAR%) entries unexpanded.
        $key   = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
        $raw   = [string]$key.GetValue("Path", "", "DoNotExpandEnvironmentNames")
        $parts = @($raw -split ";" | Where-Object { $_ -and $_ -notlike "$root\*" })
        $key.SetValue("Path", (($parts + "$springHome\bin") -join ";"), "ExpandString")
        $key.Close()
        # Also broadcasts WM_SETTINGCHANGE so new shells pick up the PATH change.
        [Environment]::SetEnvironmentVariable("SPRING_HOME", $springHome, "User")

        if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
            Write-Host "NOTE: Spring Boot CLI needs Java 17+ on PATH (tick Temurin JDK 21)." -ForegroundColor Yellow
        }
        return $true
    } catch {
        Write-Host "Spring Boot CLI install failed: $_" -ForegroundColor Red
        return $false
    }
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: 'winget' was not found on PATH. Install App Installer from the Microsoft Store." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------
foreach ($it in $items) { $it.Selected = (-not $NvimOnly) -or ($it.Group -eq "nvim") }

if ($Only) {
    # 'powershell -File' passes "a,b" as a single string
    $Only = @($Only -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($it in $items) {
        $it.Selected = [bool]($Only | Where-Object { $it.Name -like $_ -or $it.Id -like $_ })
    }
} elseif (-not $All) {
    if ([Console]::IsInputRedirected) {
        Write-Host "No interactive console; installing the pre-ticked set (use -Only to choose)." -ForegroundColor Yellow
    } elseif (-not (Show-Checklist $items)) {
        Write-Host "Cancelled; nothing installed."
        exit 0
    }
}

$selected = @($items | Where-Object Selected)
if (-not $selected.Count) {
    Write-Host "Nothing selected; nothing installed."
    exit 0
}

# ---------------------------------------------------------------------------
# Install loop
# ---------------------------------------------------------------------------
$results = @()

foreach ($it in $selected) {
    Write-Host ""
    Write-Host "=== $($it.Name) ($($it.Id)) ===" -ForegroundColor Cyan
    $ok = if ($it.Kind -eq "springboot") { Install-SpringBootCli } else { Install-Winget $it }

    Update-SessionPath
    $path = Resolve-InstallPath $it
    if ($ok) {
        Write-Host "Path: $(if ($path) { $path } else { '(not found - open a new shell and check)' })" -ForegroundColor Green
    } else {
        Write-Host "FAILED: $($it.Name)" -ForegroundColor Red
    }
    $results += [pscustomobject]@{ Ok = $ok; Name = $it.Name; Path = $path }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$failed = @($results | Where-Object { -not $_.Ok })

Write-Host ""
Write-Host "=== install-deps summary ===" -ForegroundColor Cyan
foreach ($r in $results) {
    $status = if ($r.Ok) { "ok    " } else { "FAILED" }
    $where  = if ($r.Path) { $r.Path } elseif ($r.Ok) { "(path not found - open a new shell and check)" } else { "" }
    $color  = if ($r.Ok) { "Gray" } else { "Red" }
    Write-Host ("  {0}  {1,-22} {2}" -f $status, $r.Name, $where) -ForegroundColor $color
}
Write-Host "Installed / already present: $($results.Count - $failed.Count)   Failed: $($failed.Count)"

Write-Host ""
Write-Host "=== Manual steps (not winget-installable) ===" -ForegroundColor Yellow
Write-Host "  Node.js           - nvm install 24.18.0; nvm use 24.18.0   (via nvm-windows)"
Write-Host "  0xProto Font      - download from https://github.com/0xType/0xProto (install the Nerd Font Mono variant)"
Write-Host "  Aseprite          - paid; download from https://www.aseprite.org/"
Write-Host "  Flutter           - dart pub global activate flutter   (or install from https://flutter.dev)"
Write-Host "  FVM               - dart pub global activate fvm"
Write-Host "  vcpkg             - git clone https://github.com/Microsoft/vcpkg.git"
Write-Host "  Pi Agent Harness  - powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\build-pi.ps1`""
Write-Host ""
Write-Host "=== Auto-installed by nvim itself (nothing to do) ===" -ForegroundColor DarkGray
Write-Host "  Mason: clangd, basedpyright, ruff, lua_ls, delve, Prettier, jdtls, java-debug-adapter, java-test"
Write-Host "  nvim-treesitter: parsers;   Telescope: fzf-native (built via CMake)"

if ($failed.Count) { exit 1 }
