param(
    [Parameter(Mandatory=$true)][string]$SourceOrg,
    [Parameter(Mandatory=$true)][string]$TargetOrg,
    [Parameter(Mandatory=$true)][string]$UserMappingCsv,
    [switch]$DryRun
)

function Switch-GHAuth([string]$Token, [string]$Context) {
    if (-not $Token) {
        Write-Error "Required GitHub App token for $Context is missing."
        exit 1
    }
    $env:GH_TOKEN = $Token
    $authResult = gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "GitHub CLI authentication failed for $Context."
        exit 1
    } else {
        Write-Output "GitHub CLI authenticated using token for $Context."
    }
}

function Get-Teams([string]$Org) {
    Write-Output "Retrieving teams from organization ${Org}..."
    $teams = @()
    $page = 1
    do {
        try {
            $output = gh api "orgs/$Org/teams?per_page=100&page=$page" --jq '.'
            if ($output) {
                $outputJson = $output | ConvertFrom-Json
                if ($outputJson -and $outputJson.Count -gt 0) {
                    $teams += $outputJson
                    $page++
                    Write-Output "Retrieved page $($page-1) with $($outputJson.Count) teams."
                } else {
                    break
                }
            } else {
                break
            }
        } catch {
            Write-Error "Error retrieving teams from organization ${Org} (page $page): $_"
            break
        }
    } while ($true)
    $validTeams = $teams | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }
    if ($teams.Count -ne $validTeams.Count) {
        Write-Warning "Filtered out $($teams.Count - $validTeams.Count) teams with empty names."
    }
    Write-Output "Total valid teams found in ${Org}: $($validTeams.Count)"
    return $validTeams
}

function Get-TeamByName([string]$Org, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Warning "Cannot lookup team with empty name in organization ${Org}."
        return $null
    }
    $teams = Get-Teams -Org $Org
    $matchingTeam = $teams | Where-Object { $_.name -eq $Name }
    return $matchingTeam
}

function Create-Team([string]$Org, [string]$Name, [string]$Description, [string]$Privacy, [string]$ParentTeamSlug) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Warning "Cannot create a team with an empty name in organization '${Org}'."
        return $null
    }
    if ($DryRun) {
        Write-Output "Dry-run: Would create team '${Name}' in organization '${Org}'."
        return
    }
    if ([string]::IsNullOrWhiteSpace($Privacy)) {
        $Privacy = "closed"
    }
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = "Team $Name"
    }
    try {
        $jsonBody = @{
            name = $Name
            description = $Description
            privacy = $Privacy.ToLower()
        } | ConvertTo-Json -Compress
        if (-not [string]::IsNullOrWhiteSpace($ParentTeamSlug)) {
            $parentTeam = gh api "orgs/$Org/teams/$ParentTeamSlug" --jq '.' 2>$null | ConvertFrom-Json
            if ($parentTeam -and $parentTeam.id) {
                $jsonBodyObj = $jsonBody | ConvertFrom-Json
                $jsonBodyObj | Add-Member -Name "parent_team_id" -Value $parentTeam.id -MemberType NoteProperty
                $jsonBody = $jsonBodyObj | ConvertTo-Json -Compress
            } else {
                Write-Warning "Parent team '${ParentTeamSlug}' not found. Creating '${Name}' without parent."
            }
        }
        $tempFile = New-TemporaryFile
        Set-Content -Path $tempFile.FullName -Value $jsonBody
        $response = gh api --method POST "orgs/$Org/teams" --input $tempFile.FullName
        Remove-Item -Path $tempFile.FullName
        Start-Sleep -Seconds 2
        $createdTeam = Get-TeamByName -Org $Org -Name $Name
        return $createdTeam
    } catch {
        Write-Warning "Failed to create team '${Name}' in organization '${Org}': $_"
        return $null
    }
}

function Get-TeamRepos([string]$Org, [string]$TeamSlug) {
    if ([string]::IsNullOrWhiteSpace($TeamSlug)) {
        Write-Warning "Cannot get repositories for a team with empty slug."
        return @()
    }
    $repos = @()
    $page = 1
    try {
        do {
            $output = gh api "orgs/$Org/teams/$TeamSlug/repos?per_page=100&page=$page" --jq '.' 2>$null
            if ($output) {
                $outputJson = $output | ConvertFrom-Json
                if ($outputJson -and $outputJson.Count -gt 0) {
                    $repos += $outputJson
                    $page++
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
    } catch {
        Write-Warning "Error retrieving repositories for team '${TeamSlug}': $_"
    }
    return $repos
}

function Get-Repos([string]$Org) {
    $repos = @()
    $page = 1
    try {
        do {
            $output = gh api "orgs/$Org/repos?per_page=100&page=$page" --jq '.' 2>$null
            if ($output) {
                $outputJson = $output | ConvertFrom-Json
                if ($outputJson -and $outputJson.Count -gt 0) {
                    $repos += $outputJson
                    $page++
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
    } catch {
        Write-Warning "Error retrieving repositories for organization '${Org}': $_"
    }
    $validRepos = $repos | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }
    return $validRepos
}

function Set-TeamRepoPermission([string]$Org, [string]$TeamSlug, [string]$RepoName, [string]$Permission) {
    if ([string]::IsNullOrWhiteSpace($TeamSlug) -or [string]::IsNullOrWhiteSpace($RepoName) -or [string]::IsNullOrWhiteSpace($Permission)) {
        Write-Warning "Cannot set permission with empty values: TeamSlug='${TeamSlug}', RepoName='${RepoName}', Permission='${Permission}'."
        return
    }
    if ($DryRun) {
        Write-Output "Dry-run: Would set permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}'."
        return
    }
    $maxAttempts = 5
    $success = $false
    $attempt = 1
    while (-not $success -and $attempt -le $maxAttempts) {
        try {
            gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" --field permission="$Permission"
            if ($LASTEXITCODE -eq 0) {
                Write-Output "Successfully set permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}'."
                $success = $true
            } else {
                Write-Warning "Attempt ${attempt}: Failed to set permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}'. Retrying in 60s."
                Start-Sleep -Seconds 60
                $attempt++
            }
        } catch {
            Write-Warning "Attempt ${attempt}: Error setting permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}': $_. Retrying in 60s."
            Start-Sleep -Seconds 60
            $attempt++
        }
    }
    if (-not $success) {
        Write-Warning "Giving up on setting permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}' after $maxAttempts attempts."
    }
    Start-Sleep -Seconds 3
}

function Get-TeamMembers([string]$Org, [string]$TeamSlug) {
    if ([string]::IsNullOrWhiteSpace($TeamSlug)) {
        Write-Warning "Cannot get members for a team with empty slug."
        return @()
    }
    $members = @()
    $page = 1
    try {
        do {
            $output = gh api "orgs/$Org/teams/$TeamSlug/members?per_page=100&page=$page" --jq '.' 2>$null
            if ($output) {
                $outputJson = $output | ConvertFrom-Json
                if ($outputJson -and $outputJson.Count -gt 0) {
                    $members += $outputJson
                    $page++
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
    } catch {
        Write-Warning "Error retrieving members for team '${TeamSlug}': $_"
    }
    $validMembers = $members | Where-Object { -not [string]::IsNullOrWhiteSpace($_.login) }
    return $validMembers
}

function Add-TeamMember([string]$Org, [string]$TeamSlug, [string]$Username, [string]$Role = "member") {
    if ([string]::IsNullOrWhiteSpace($TeamSlug) -or [string]::IsNullOrWhiteSpace($Username)) {
        Write-Warning "Cannot add member with empty values: TeamSlug='${TeamSlug}', Username='${Username}'."
        return
    }
    if ($DryRun) {
        Write-Output "Dry-run: Would add user '${Username}' to team '${TeamSlug}' with role '${Role}'."
        return
    }
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/memberships/$Username" --field role="$Role"
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Successfully added user '${Username}' to team '${TeamSlug}'."
        } else {
            Write-Warning "Failed to add user '${Username}' to team '${TeamSlug}'."
        }
    } catch {
        Write-Warning "Error adding user '${Username}' to team '${TeamSlug}': $_"
    }
}

function Get-UserMapping([string]$CsvPath) {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "User mapping CSV file not found at path: ${CsvPath}"
        exit 1
    }
    try {
        $userMap = Import-Csv -Path $CsvPath
        if ($userMap.Count -gt 0) {
            $firstRow = $userMap[0]
            if (-not ($firstRow.PSObject.Properties.Name -contains "SourceUsername") -or 
                -not ($firstRow.PSObject.Properties.Name -contains "TargetUsername")) {
                Write-Warning "User mapping CSV does not contain required columns 'SourceUsername' and/or 'TargetUsername'."
                $possibleSourceColumns = $firstRow.PSObject.Properties.Name | Where-Object { $_ -like "*Source*" -or $_ -like "*From*" }
                $possibleTargetColumns = $firstRow.PSObject.Properties.Name | Where-Object { $_ -like "*Target*" -or $_ -like "*To*" }
                if ($possibleSourceColumns -and $possibleTargetColumns) {
                    $newUserMap = @()
                    foreach ($row in $userMap) {
                        $newUserMap += [PSCustomObject]@{
                            SourceUsername = $row.$($possibleSourceColumns[0])
                            TargetUsername = $row.$($possibleTargetColumns[0])
                        }
                    }
                    return $newUserMap
                } else {
                    Write-Error "Cannot determine source and target username columns in the CSV. Please rename columns to 'SourceUsername' and 'TargetUsername'."
                    exit 1
                }
            }
        }
        return $userMap
    } catch {
        Write-Error "Failed to read user mapping CSV: $_"
        exit 1
    }
}

# Main execution starts here
Write-Output "Starting GitHub Teams migration from '${SourceOrg}' to '${TargetOrg}'"

if (-not (Test-Path $UserMappingCsv)) {
    Write-Error "User mapping file not found: ${UserMappingCsv}"
    exit 1
}

# 1. Authenticate for source organization operations
Switch-GHAuth $env:SOURCE_GH_APP_TOKEN "source organization"

# 2. Get all teams from the source organization
$sourceTeams = Get-Teams -Org $SourceOrg
Write-Output "Found $($sourceTeams.Count) teams in source organization."

# 3. Authenticate for target organization operations
Switch-GHAuth $env:TARGET_GH_APP_TOKEN "target organization"

# 4. Get current teams in target org
$existingTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Found $($existingTargetTeams.Count) existing teams in target organization."

$processedTeams = @{}

# 5. Create all parent teams (teams without parent)
foreach ($team in $sourceTeams | Where-Object { -not $_.parent }) {
    if ([string]::IsNullOrWhiteSpace($team.name)) { continue }
    $existingTeam = $existingTargetTeams | Where-Object { $_.name -eq $team.name }
    if ($existingTeam) {
        $processedTeams[$team.name] = $existingTeam
    } else {
        $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
        if ($result) {
            $processedTeams[$team.name] = $result
        }
    }
}

Start-Sleep -Seconds 5
$targetTeams = Get-Teams -Org $TargetOrg

# 6. Create child teams
foreach ($team in $sourceTeams | Where-Object { $_.parent }) {
    if ([string]::IsNullOrWhiteSpace($team.name)) { continue }
    $existingTeam = $targetTeams | Where-Object { $_.name -eq $team.name }
    if ($existingTeam) {
        $processedTeams[$team.name] = $existingTeam
    } else {
        $parentTeamName = $team.parent.name
        if ([string]::IsNullOrWhiteSpace($parentTeamName)) {
            $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
        } else {
            $parentTeam = $targetTeams | Where-Object { $_.name -eq $parentTeamName }
            if ($parentTeam) {
                $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamSlug $parentTeam.slug
            } else {
                $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
            }
        }
        if ($result) {
            $processedTeams[$team.name] = $result
        }
    }
}

Start-Sleep -Seconds 5
$finalTargetTeams = Get-Teams -Org $TargetOrg

# 7. Set repository permissions
$targetRepos = Get-Repos -Org $TargetOrg
foreach ($sourceTeam in $sourceTeams) {
    if ([string]::IsNullOrWhiteSpace($sourceTeam.name) -or [string]::IsNullOrWhiteSpace($sourceTeam.slug)) { continue }
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    if ($targetTeam) {
        Switch-GHAuth $env:SOURCE_GH_APP_TOKEN "source organization"
        $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeam.slug
        Switch-GHAuth $env:TARGET_GH_APP_TOKEN "target organization"
        foreach ($repo in $teamRepos) {
            if ([string]::IsNullOrWhiteSpace($repo.name)) { continue }
            $targetRepo = $targetRepos | Where-Object { $_.name -eq $repo.name }
            if ($targetRepo) {
                $permission = if ($repo.role_name) { $repo.role_name } else { "pull" }
                Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $targetTeam.slug -RepoName $targetRepo.name -Permission $permission
            }
        }
    }
}

# 8. Add team members using the user mapping
$userMapping = Get-UserMapping -CsvPath $UserMappingCsv
foreach ($sourceTeam in $sourceTeams) {
    if ([string]::IsNullOrWhiteSpace($sourceTeam.name) -or [string]::IsNullOrWhiteSpace($sourceTeam.slug)) { continue }
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    if ($targetTeam) {
        Switch-GHAuth $env:SOURCE_GH_APP_TOKEN "source organization"
        $teamMembers = Get-TeamMembers -Org $SourceOrg -TeamSlug $sourceTeam.slug
        Switch-GHAuth $env:TARGET_GH_APP_TOKEN "target organization"
        foreach ($member in $teamMembers) {
            if ([string]::IsNullOrWhiteSpace($member.login)) { continue }
            $mappedUser = $userMapping | Where-Object { $_.SourceUsername -eq $member.login }
            if ($mappedUser -and -not [string]::IsNullOrWhiteSpace($mappedUser.TargetUsername)) {
                $targetUsername = $mappedUser.TargetUsername
                Add-TeamMember -Org $TargetOrg -TeamSlug $targetTeam.slug -Username $targetUsername -Role ($member.role ?? "member")
            }
        }
    }
}

Write-Output "GitHub Teams migration completed."
