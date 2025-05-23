param (
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [string]$Condition,
    [string]$LogFile = "$PSScriptRoot\SyncMedia.log",
    [switch]$List,
    [switch]$ListSource,
    [switch]$ListDestination,
    [switch]$Copy,
    [switch]$Difference,
    [switch]$Delete,
    [switch]$WhatIf
)

function Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $message"
    Write-Host $line
    $line | Out-File -FilePath $LogFile -Encoding utf8 -Append
}

function Get-YearFromName($name) {
    if ($name -match "\((\d{4})\)") {
        return [int]$matches[1]
    }
    return $null
}

function Match-Condition($name) {
    if (-not $Condition) { return $true }

    $year = Get-YearFromName $name
    if ($Condition -match "Year\s*([<>=!]+)\s*(\d{4})") {
        $op = $matches[1]
        $val = [int]$matches[2]

        if ($year -eq $null) { return $false }

        switch ($op) {
            "==" { return $year -eq $val }
            ">=" { return $year -ge $val }
            "<=" { return $year -le $val }
            ">"  { return $year -gt $val }
            "<"  { return $year -lt $val }
            "!=" { return $year -ne $val }
        }
    }

    return $false
}

function Get-MediaItems($path) {
    Get-ChildItem -Path $path -Directory -Recurse | Where-Object {
        Match-Condition $_.Name
    } | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            FullPath = $_.FullName
            RelativePath = $_.FullName.Substring($path.Length).TrimStart('\')
        }
    }
}

function Get-FolderContentSizeGB($items) {
    $totalBytes = 0
    foreach ($item in $items) {
        if (Test-Path $item.FullPath) {
            Get-ChildItem -Path $item.FullPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $totalBytes += $_.Length
            }
        }
    }
    return [math]::Round($totalBytes / 1GB, 2)
}

function Sync-Media {
    Log "----- Sync started -----"
    Log "Source: $SourcePath"
    Log "Destination: $DestinationPath"
    if ($Condition) { Log "Condition: $Condition" }
    if ($Difference) { Log "Mode: Difference only" }
    if ($WhatIf) { Log "Mode: WhatIf (simulation only)" }

    $sourceItems = Get-MediaItems $SourcePath
    $destinationItems = Get-ChildItem -Path $DestinationPath -Directory -Recurse

    $destinationLookup = @{}
    foreach ($dest in $destinationItems) {
        $destinationLookup[$dest.FullName.ToLower()] = $true
    }

    $itemsToCopy = @()
    foreach ($item in $sourceItems) {
        $targetPath = Join-Path $DestinationPath $item.RelativePath
        $exists = $destinationLookup.ContainsKey($targetPath.ToLower())
        if ($Difference) {
            if (-not $exists) {
                $itemsToCopy += $item
            }
        } else {
            $itemsToCopy += $item
        }
    }

    if ($List -or $ListSource) {
        Log "--- SOURCE FILES ---"
        $sourceItems | ForEach-Object { Log $_.RelativePath }
    }

    if ($ListDestination) {
        Log "--- DESTINATION FILES ---"
        $destinationItems | ForEach-Object { Log $_.Name }
    }

    if ($Copy) {
        Log "--- FILES TO COPY ---"
        $itemsToCopy | ForEach-Object { Log $_.RelativePath }

        $totalGB = Get-FolderContentSizeGB $itemsToCopy
        $folderCount = $itemsToCopy.Count
        Log "$folderCount folder(s) with a total of $totalGB GB will be copied."

        $confirmation = Read-Host "`nDo you want to copy these files? (y/n)"
        if ($confirmation -eq "y") {
            foreach ($item in $itemsToCopy) {
                $targetPath = Join-Path $DestinationPath $item.RelativePath
                $targetDir = Split-Path $targetPath -Parent
                if (-not (Test-Path $targetDir) -and -not $WhatIf) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                if ($WhatIf) {
                    Log "WhatIf: Would copy $($item.RelativePath)"
                } else {
                    Copy-Item -Path $item.FullPath -Destination $targetPath -Recurse -Force
                    Log "Copied: $($item.RelativePath)"
                }
            }
        }
    }

    if ($Delete -and $Difference) {
        $itemsToDelete = $sourceItems | Where-Object {
            $targetPath = Join-Path $DestinationPath $_.RelativePath
            Test-Path $targetPath
        }

        if ($itemsToDelete.Count -gt 0) {
            Log "--- FILES TO DELETE (on source) ---"
            $itemsToDelete | ForEach-Object { Log $_.RelativePath }

            $totalGB = Get-FolderContentSizeGB $itemsToDelete
            $folderCount = $itemsToDelete.Count
            Log "$folderCount folder(s) with a total of $totalGB GB will be deleted."

            $confirmation = Read-Host "`nDo you want to delete these files from source? (y/n)"
            if ($confirmation -eq "y") {
                foreach ($item in $itemsToDelete) {
                    if ($WhatIf) {
                        Log "WhatIf: Would delete $($item.RelativePath)"
                    } else {
                        Remove-Item -Path $item.FullPath -Recurse -Force
                        Log "Deleted: $($item.RelativePath)"
                    }
                }
            }
        }
    }

    Log "----- Sync finished -----`n"
}

Sync-Media
