# gt <name>          jump to a saved directory
# gt --add [path]    save path (default: current directory) under a name you're prompted for
# gt --edit [name]   change a saved entry's path and/or name (picks from a list if no name given)
# gt --remove [name] delete a saved entry (picks from a list if no name given)
# gt                 list saved names
# Lives on PATH; Set-Location in a script carries over to the calling shell.
# Names and paths are stored in gt-paths.json next to this script (gitignored;
# copy gt-paths.sample.json to start, or just use gt --add).
param(
    [Parameter(Position = 0)][string]$name,
    [Parameter(Position = 1)][string]$path
)

$store = Join-Path $PSScriptRoot 'gt-paths.json'

function Read-Store {
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $store) {
        $json = Get-Content -LiteralPath $store -Raw | ConvertFrom-Json
        if ($json) { $json.PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value } }
    }
    return $map
}

function Write-Store($map) {
    $text = ([pscustomobject]$map | ConvertTo-Json) + "`n"
    [IO.File]::WriteAllText($store, $text, (New-Object Text.UTF8Encoding $false))
}

# Returns the directory as a forward-slash absolute path, or $null if it isn't one.
function Resolve-Dir([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "Not a directory: $dir"
        return $null
    }
    return (Resolve-Path -LiteralPath $dir).ProviderPath.Replace('\', '/')
}

# Returns the given key, or one picked from a numbered list; $null if it isn't saved.
function Select-Entry($map, [string]$key, [string]$verb) {
    if ($map.Count -eq 0) { Write-Host "No saved paths. Add one with: gt --add [path]"; return $null }
    if (-not $key) {
        $keys = @($map.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            Write-Host ("{0,3}) {1,-12} {2}" -f ($i + 1), $keys[$i], $map[$keys[$i]])
        }
        $pick = Read-Host "Entry to $verb (number or name)"
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $keys.Count) {
            $key = $keys[[int]$pick - 1]
        } else {
            $key = $pick
        }
    }
    if (-not $map.Contains($key)) { Write-Host "Unknown target: $key"; return $null }
    return $key
}

$paths = Read-Store

if ($name -eq '--remove') {
    $key = Select-Entry $paths $path 'remove'
    if (-not $key) { return }
    $answer = Read-Host "Remove '$key' -> $($paths[$key])? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Write-Host "Not removed."; return }
    $paths.Remove($key)
    Write-Store $paths
    Write-Host "Removed $key"
    return
}

if ($name -eq '--edit') {
    $key = Select-Entry $paths $path 'modify'
    if (-not $key) { return }

    $newPath = Read-Host "New path for '$key' (Enter keeps $($paths[$key]), . for current directory)"
    if ($newPath) {
        $newPath = Resolve-Dir $newPath
        if (-not $newPath) { return }
    } else {
        $newPath = $paths[$key]
    }

    $newKey = Read-Host "New name (Enter keeps '$key')"
    if (-not $newKey) { $newKey = $key }
    if ($newKey -ne $key -and $paths.Contains($newKey)) {
        $answer = Read-Host "'$newKey' already points to $($paths[$newKey]). Overwrite? [y/N]"
        if ($answer -notmatch '^(y|yes)$') { Write-Host "Not saved."; return }
    }

    # Rebuild so a renamed entry keeps its position in the file.
    $updated = [ordered]@{}
    foreach ($k in $paths.Keys) {
        if ($k -eq $key) { $updated[$newKey] = $newPath }
        elseif ($k -ne $newKey) { $updated[$k] = $paths[$k] }
    }
    Write-Store $updated
    Write-Host "Saved $newKey -> $newPath"
    return
}

if ($name -eq '--add') {
    if (-not $path) { $path = (Get-Location).Path }
    $full = Resolve-Dir $path
    if (-not $full) { return }

    $default = Split-Path $full -Leaf
    $key = Read-Host "Name for $full [$default]"
    if (-not $key) { $key = $default }

    if ($paths.Contains($key)) {
        $answer = Read-Host "'$key' already points to $($paths[$key]). Overwrite? [y/N]"
        if ($answer -notmatch '^(y|yes)$') { Write-Host "Not saved."; return }
    }
    $paths[$key] = $full
    Write-Store $paths
    Write-Host "Saved $key -> $full"
    return
}

if (-not $name) {
    if ($paths.Count -eq 0) { Write-Host "No saved paths. Add one with: gt --add [path]"; return }
    $paths.GetEnumerator() | ForEach-Object { "{0,-12} {1}" -f $_.Key, $_.Value }
    return
}

if ($paths.Contains($name)) {
    Set-Location -LiteralPath $paths[$name]
} else {
    Write-Host "Unknown target: $name"
}
