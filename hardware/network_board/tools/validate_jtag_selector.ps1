param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('location', 'serial')]
    [string] $Kind,

    [Parameter(Mandatory = $true)]
    [string] $Value
)

$valid = switch ($Kind) {
    'location' { $Value -match '^\d+-\d+(?:\.\d+)*$' }
    'serial'   { $Value -match '^[A-Za-z0-9._-]+$' }
}

if (-not $valid) {
    exit 1
}
exit 0
