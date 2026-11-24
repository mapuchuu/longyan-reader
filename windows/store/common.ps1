# Shared by pack.ps1, bundle.ps1 and test.ps1.

# identity.txt's three values, the one place they're kept.
function Read-Identity {
    $id = @{}
    foreach ($line in Get-Content "$PSScriptRoot/identity.txt") {
        if ($line -match '^\s*(#|$)') { continue }
        $k, $v = $line -split '=', 2
        $id[$k.Trim()] = $v.Trim()
    }
    foreach ($k in 'IdentityName', 'Publisher', 'PublisherDisplayName') { if (-not $id[$k]) { throw "identity.txt has no $k" } }
    if ($id.IdentityName -notmatch '^[-.A-Za-z0-9]{3,50}$') { throw "identity.txt: IdentityName '$($id.IdentityName)' isn't a package name" }
    if ($id.Publisher -notmatch '^CN=') { throw "identity.txt: Publisher should start with CN=" }
    $id
}

# The package version from the exe (the csproj's <Version>): a.b.c.0. The Store needs the
# last part to be 0.
function Get-PackageVersion([string] $exe) {
    $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-Path $exe)).FileVersion
    $p = @($v.Split('.') | ForEach-Object { [int]$_ })
    while ($p.Count -lt 3) { $p += 0 }
    "{0}.{1}.{2}.0" -f $p[0], $p[1], $p[2]
}

# makeappx, makepri and signtool from the newest Windows 10/11 SDK on the machine, for its
# CPU when the SDK has that build, otherwise the x64 one (which ARM64 Windows runs too).
function Find-SdkTool([string] $name) {
    $kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $cpu = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    foreach ($a in $cpu, 'x64') {
        $tool = Get-ChildItem "$kits\10.*\$a\$name" -ErrorAction SilentlyContinue |
            Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
        if ($tool) { return $tool.FullName }
    }
    throw "no $name in $kits"
}
