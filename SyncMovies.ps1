# Define script parameters with options for various operations
param (
    [Parameter(Mandatory = $true)][string]$SourcePath,         # Required source directory
    [Parameter(Mandatory = $true)][string]$DestinationPath,    # Required destination directory
    [string]$Condition,                                        # Optional filter condition based on year
    [string]$LogFile = "$PSScriptRoot\SyncMedia.log",          # Path to log file (default in script folder)
    [switch]$List,                                             # Flag to list all matched source directories
    [switch]$ListSource,                                       # Flag to list only source items
    [switch]$ListDestination,                                  # Flag to list destination items
    [switch]$Copy,                                             # Flag to enable copy operation
    [switch]$Difference,                                       # Flag to only act on differences
    [switch]$Delete,                                           # Flag to enable delete operation
    [switch]$WhatIf,                                           # Simulation mode (no actual changes)
    [switch]$FullSize                                          # Flag to only calculate total size
)

# Logs a message with timestamp to console and log file
function Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $message"
    Write-Host $line
    $line | Out-File -FilePath $LogFile -Encoding utf8 -Append
}

# Extracts a 4-digit year enclosed in parentheses from a name string
function Get-YearFromName($name) {
    if ($name -match "\((\d{4})\)") {
        return [int]$matches[1]
    }
    return $null
}

# Checks if a given name matches the user-defined condition (e.g., "Year <= 2000")
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

# Retrieves all subdirectories that match the filtering condition
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

# Calculates total size (in GB) of files inside provided directories
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

# Main synchronization function
function Sync-Media {

    # If only the total size is requested, calculate and exit
    if ($FullSize) {
        $sourceItems = Get-MediaItems $SourcePath
        $totalGB = Get-FolderContentSizeGB $sourceItems
        Log "Total size of filtered source directory: $totalGB GB"
        return
    }

    # Logging basic information
    Log "----- Sync started -----"
    Log "Source: $SourcePath"
    Log "Destination: $DestinationPath"
    if ($Condition) { Log "Condition: $Condition" }
    if ($Difference) { Log "Mode: Difference only" }
    if ($WhatIf) { Log "Mode: WhatIf (simulation only)" }

    # Get and filter source and destination directories
    $sourceItems = Get-MediaItems $SourcePath
    $destinationItems = Get-ChildItem -Path $DestinationPath -Directory -Recurse

    # Build lookup table of destination paths (case-insensitive)
    $destinationLookup = @{}
    foreach ($dest in $destinationItems) {
        $destinationLookup[$dest.FullName.ToLower()] = $true
    }

    # Determine which items to copy
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

    # Optionally list source and/or destination content
    if ($List -or $ListSource) {
        Log "--- SOURCE FILES ---"
        $sourceItems | ForEach-Object { Log $_.RelativePath }
    }

    if ($ListDestination) {
        Log "--- DESTINATION FILES ---"
        $destinationItems | ForEach-Object { Log $_.Name }
    }

    # Perform the copy operation
    if ($Copy) {
        Log "--- FILES TO COPY ---"
        $itemsToCopy | ForEach-Object { Log $_.RelativePath }

        $totalGB = Get-FolderContentSizeGB $itemsToCopy
        $folderCount = $itemsToCopy.Count
        Log "$folderCount folder(s) with a total of $totalGB GB will be copied."

        $confirmation = Read-Host "`nDo you want to copy these files? (y/n)"
        if ($confirmation -eq "y") {
            $i = 0
            foreach ($item in $itemsToCopy) {
                $i++
                $targetPath = Join-Path $DestinationPath $item.RelativePath
                $targetDir = Split-Path $targetPath -Parent
                if (-not (Test-Path $targetDir) -and -not $WhatIf) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                if ($WhatIf) {
                    Log "WhatIf: Would copy $($item.RelativePath) (Progress: $i/$folderCount)"
                } else {
                    Copy-Item -Path $item.FullPath -Destination $targetPath -Recurse -Force
                    Log "Copied: $($item.RelativePath) (Progress: $i/$folderCount)"
                }
            }
        }
    }

    # Optionally delete items from source if they already exist in destination
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
                $i = 0
                foreach ($item in $itemsToDelete) {
                    $i++
                    if ($WhatIf) {
                        Log "WhatIf: Would delete $($item.RelativePath) (Progress: $i/$folderCount)"
                    } else {
                        Remove-Item -Path $item.FullPath -Recurse -Force
                        Log "Deleted: $($item.RelativePath) (Progress: $i/$folderCount)"
                    }
                }
            }
        }
    }

    Log "----- Sync finished -----`n"
}

# Execute the main function
Sync-Media
