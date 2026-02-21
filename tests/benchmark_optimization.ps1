
$iterations = 10000
$inheritanceString = "BaseClass, IInterface1, IInterface2, IInterface3, IInterface4, AnotherClass"

Write-Host "Benchmarking with $iterations iterations..."

$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt $iterations; $i++) {
    $baseClass = ""
    $interfaces = @()
    # ORIGINAL LOGIC
    if ($inheritanceString) {
        $inheritParts = $inheritanceString -split ',' | ForEach-Object { $_.Trim() }
        foreach ($part in $inheritParts) {
            if ($part -match '^I[A-Z]') {
                $interfaces += $part
            } elseif (-not $baseClass) {
                $baseClass = $part
            } else {
                $interfaces += $part
            }
        }
    }
}

$sw.Stop()
Write-Host "Original: $($sw.ElapsedMilliseconds) ms"

$sw.Reset()
$sw.Start()

for ($i = 0; $i -lt $iterations; $i++) {
    $baseClass = ""
    $interfaces = @()
    # OPTIMIZED LOGIC
    if ($inheritanceString) {
        $inheritParts = $inheritanceString -split ','
        foreach ($rawPart in $inheritParts) {
            $part = $rawPart.Trim()
            if ($part -match '^I[A-Z]') {
                $interfaces += $part
            } elseif (-not $baseClass) {
                $baseClass = $part
            } else {
                $interfaces += $part
            }
        }
    }
}

$sw.Stop()
Write-Host "Optimized (No Pipeline): $($sw.ElapsedMilliseconds) ms"

$sw.Reset()
$sw.Start()

for ($i = 0; $i -lt $iterations; $i++) {
    $baseClass = ""
    $interfaces = [System.Collections.Generic.List[string]]::new()
    # OPTIMIZED LOGIC + List
    if ($inheritanceString) {
        $inheritParts = $inheritanceString -split ','
        foreach ($rawPart in $inheritParts) {
            $part = $rawPart.Trim()
            if ($part -match '^I[A-Z]') {
                $interfaces.Add($part)
            } elseif (-not $baseClass) {
                $baseClass = $part
            } else {
                $interfaces.Add($part)
            }
        }
    }
    # To match original output type if needed, but array += is also slow.
    # $interfacesArray = $interfaces.ToArray()
}

$sw.Stop()
Write-Host "Optimized (No Pipeline + List): $($sw.ElapsedMilliseconds) ms"
