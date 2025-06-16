param(
    [Parameter(Mandatory=$true)][string]$SourceOrg,
    [Parameter(Mandatory=$true)][string]$TargetOrg,
    [Parameter(Mandatory=$true)][string]$UserMappingCsv,
    [switch]$DryRun
)

function GhAuth([string]$EnvVarName) {
    $Token = (Get-Item "env:$EnvVarName").Value
    if (-not $Token) {
        Write-Error "Environment variable ${EnvVarName} is not set or empty."
        exit 1
    }
    $env:GH_TOKEN = $Token
    $authResult = gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "GitHub CLI authentication failed using ${EnvVarName}."
        exit 1
    } else {
        Write-Output "GitHub CLI authenticated using ${EnvVarName}."
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
    # Filter out any teams with empty names or slugs
    $validTeams = $teams | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) -and -not [string]::IsNullOrWhiteSpace($_.slug) }
    if ($teams.Count -ne $validTeams.Count) {
        Write-Warning "Filtered out $($teams.Count - $validTeams.Count) teams with empty names or slugs."
    }
    Write-Output "Total valid teams found in ${Org}: $($validTeams.Count)"
    return $validTeams
}

function Get-TeamByName([string]$Org, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Warning "Cannot lookup team with empty name in organization ${Org}."
        return $null
    }
    Write-Output "Looking for team with name '${Name}' in organization ${Org}..."
    $teams = Get-Teams -Org $Org
    $matchingTeam = $teams | Where-Object { $_.name -eq $Name }
    if ($matchingTeam) {
        Write-Output "Found team: $($matchingTeam.name) (slug: $($matchingTeam.slug))"
        return $matchingTeam
    } else {
        Write-Output "No team found with name '${Name}' in organization ${Org}."
        return $null
    }
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
    Write-Output "Creating team '${Name}' in organization '${Org}'..."
    if ([string]::IsNullOrWhiteSpace($Privacy)) {
        $Privacy = "closed"
        Write-Output "Using default privacy setting: closed"
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
                Write-Output "Found parent team '${ParentTeamSlug}' with ID: $($parentTeam.id)"
                $jsonBodyObj = $jsonBody | ConvertFrom-Json
                $jsonBodyObj | Add-Member -Name "parent_team_id" -Value $parentTeam.id -MemberType NoteProperty
                $jsonBody = $jsonBodyObj | ConvertTo-Json -Compress
            } else {
                Write-Warning "Parent team '${ParentTeamSlug}' not found. Creating '${Name}' without parent."
            }
        }
        Write-Output "Team creation request body: $jsonBody"
        $tempFile = New-TemporaryFile
        Set-Content -Path $tempFile.FullName -Value $jsonBody
        $response = gh api --method POST "orgs/$Org/teams" --input $tempFile.FullName
        Remove-Item -Path $tempFile.FullName
        Start-Sleep -Seconds 2
        $createdTeam = Get-TeamByName -Org $Org -Name $Name
        if ($createdTeam) {
            Write-Output "Successfully created team '${Name}' with slug '$($createdTeam.slug)'."
            return $createdTeam
        } else {
            Write-Warning "Team creation API call was made but team '${Name}' not found afterward."
            return $null
        }
    }
    catch {
        Write-Warning "Failed to create team '${Name}' in organization '${Org}': $_"
        Write-Output "Error details: $($Error[0])"
        return $null
    }
}

function Get-TeamRepos([string]$Org, [string]$TeamSlug) {
    if ([string]::IsNullOrWhiteSpace($TeamSlug)) {
        Write-Warning "Cannot get repositories for a team with empty slug."
        return @()
    }
    Write-Output "Getting repositories for team '${TeamSlug}' in organization '${Org}'..."
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
                    Write-Output "Retrieved $($outputJson.Count) repos for team '${TeamSlug}' (page $($page-1))."
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
    }
    catch {
        Write-Warning "Error retrieving repositories for team '${TeamSlug}': $_"
    }
    Write-Output "Total repositories for team '${TeamSlug}': $($repos.Count)"
    return $repos
}

function Get-Repos([string]$Org) {
    Write-Output "Getting all repositories in organization '${Org}'..."
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
                    Write-Output "Retrieved $($outputJson.Count) repos from '${Org}' (page $($page-1))."
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
    }
    catch {
        Write-Warning "Error retrieving repositories for organization '${Org}': $_"
    }
    # Filter out repositories with empty names
    $validRepos = $repos | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }
    Write-Output "Total valid repositories for organization '${Org}': $($validRepos.Count)"
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
    Write-Output "Setting permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}'..."
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" --field permission="$Permission"
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Successfully set permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}'."
        } else {
            Write-Warning "Failed to set permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}'."
        }
    } catch {
        Write-Warning "Error setting permission '${Permission}' for team '${TeamSlug}' on repository '${RepoName}': $_"
    }
}

function Get-TeamMembers([string]$Org, [string]$TeamSlug) {
    if ([string]::IsNullOrWhiteSpace($TeamSlug)) {
        Write-Warning "Cannot get members for a team with empty slug."
        return @()
    }
    Write-Output "Getting members for team '${TeamSlug}' in organization '${Org}'..."
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
                    Write-Output "Retrieved $($outputJson.Count) members for team '${TeamSlug}' (page $($page-1))."
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
    }
    catch {
        Write-Warning "Error retrieving members for team '${TeamSlug}': $_"
    }
    $validMembers = $members | Where-Object { -not [string]::IsNullOrWhiteSpace($_.login) }
    Write-Output "Total valid members for team '${TeamSlug}': $($validMembers.Count)"
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
    Write-Output "Adding user '${Username}' to team '${TeamSlug}' with role '${Role}'..."
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
                    Write-Output "Using inferred column names: Source='$($possibleSourceColumns[0])', Target='$($possibleTargetColumns[0])'"
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

Write-Output "Authenticating with source organization..."
GhAuth "SOURCE_PAT"
Write-Output "Fetching teams from source organization '${SourceOrg}'..."
$sourceTeams = Get-Teams -Org $SourceOrg
Write-Output "Found $($sourceTeams.Count) teams in source organization."
Write-Output "Source Teams:"
$sourceTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

Write-Output "Authenticating with target organization..."
GhAuth "TARGET_PAT"
Write-Output "Checking existing teams in target organization..."
$existingTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Found $($existingTargetTeams.Count) existing teams in target organization."
Write-Output "Existing Target Teams:"
$existingTargetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

$processedTeams = @{}

Write-Output "Creating parent teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { -not $_.parent }) {
    if ([string]::IsNullOrWhiteSpace($team.name)) { Write-Warning "Skipping team with empty name."; continue }
    Write-Output "Processing parent team: $($team.name)"
    $existingTeam = $existingTargetTeams | Where-Object { $_.name -eq $team.name }
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization with slug '$($existingTeam.slug)'."
        $processedTeams[$team.name] = $existingTeam
    } else {
        Write-Output "Creating team '$($team.name)' in target organization."
        $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
        if ($result) {
            Write-Output "Successfully created team '$($team.name)' with slug '$($result.slug)'."
            $processedTeams[$team.name] = $result
        } else {
            Write-Warning "Failed to create team '$($team.name)' in target organization."
        }
    }
}

Write-Output "Waiting for API propagation..."
Start-Sleep -Seconds 5
$targetTeams = Get-Teams -Org $TargetOrg
Write-Output "After creating parent teams: $($targetTeams.Count) teams in target organization."
Write-Output "Updated Target Teams:"
$targetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

Write-Output "Creating child teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { $_.parent }) {
    if ([string]::IsNullOrWhiteSpace($team.name)) { Write-Warning "Skipping child team with empty name."; continue }
    Write-Output "Processing child team: $($team.name)"
    $existingTeam = $targetTeams | Where-Object { $_.name -eq $team.name }
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization with slug '$($existingTeam.slug)'."
        $processedTeams[$team.name] = $existingTeam
    } else {
        $parentTeamName = $team.parent.name
        if ([string]::IsNullOrWhiteSpace($parentTeamName)) {
            Write-Warning "Child team '$($team.name)' has a parent with empty name. Creating without parent."
            $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
        } else {
            $parentTeam = $targetTeams | Where-Object { $_.name -eq $parentTeamName }
            if ($parentTeam) {
                Write-Output "Creating child team '$($team.name)' under parent '${parentTeamName}' in target organization."
                $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamSlug $parentTeam.slug
            } else {
                Write-Output "Parent team '${parentTeamName}' not found in target organization. Creating '$($team.name)' without parent."
                $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
            }
        }
        if ($result) {
            Write-Output "Successfully created child team '$($team.name)' with slug '$($result.slug)'."
            $processedTeams[$team.name] = $result
        } else {
            Write-Warning "Failed to create child team '$($team.name)' in target organization."
        }
    }
}

Write-Output "Waiting for API propagation..."
Start-Sleep -Seconds 5
$finalTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Final count after creating all teams: $($finalTargetTeams.Count) teams in target organization."
Write-Output "Teams in target organization:"
$finalTargetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

# ======== Optimized Permission Setting Section ========

Write-Output "Setting repository permissions for teams..."
$targetRepos = Get-Repos -Org $TargetOrg

# Build a hashtable for fast repo lookup
$targetReposMap = @{}
foreach ($repo in $targetRepos | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }) {
    $targetReposMap[$repo.name] = $repo
}

$sourceTeamsWithSlugs = $sourceTeams | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) -and -not [string]::IsNullOrWhiteSpace($_.slug) }
$teamTotal = $sourceTeamsWithSlugs.Count
$teamIndex = 1
foreach ($sourceTeam in $sourceTeamsWithSlugs) {
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    if ($targetTeam) {
        $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeam.slug
        $teamReposWithNames = $teamRepos | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }
        $repoTotal = $teamReposWithNames.Count
        $repoIndex = 1
        foreach ($repo in $teamReposWithNames) {
            $targetRepo = $targetReposMap[$repo.name]
            if ($targetRepo) {
                $permission = if ($repo.role_name) { $repo.role_name } else { "pull" }
                Write-Output "[$teamIndex/$teamTotal][$repoIndex/$repoTotal] Setting permission '${permission}' for team '$($targetTeam.name)' (slug: $($targetTeam.slug)) on repository '$($targetRepo.name)'."
                Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $targetTeam.slug -RepoName $targetRepo.name -Permission $permission
            } else {
                Write-Output "Repository '$($repo.name)' not found in target organization. Skipping."
            }
            $repoIndex++
        }
    }
    $teamIndex++
}

# ========== End Optimized Permission Setting Section ==========

Write-Output "Adding team members using user mapping from ${UserMappingCsv}..."
try {
    $userMapping = Get-UserMapping -CsvPath $UserMappingCsv
    Write-Output "Loaded user mapping with $($userMapping.Count) entries."
} catch {
    Write-Warning "Failed to load user mapping: $_"
    $userMapping = @()
}

foreach ($sourceTeam in $sourceTeams | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) -and -not [string]::IsNullOrWhiteSpace($_.slug) }) {
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    if ($targetTeam) {
        Write-Output "Processing members for team: $($targetTeam.name)"
        $teamMembers = Get-TeamMembers -Org $SourceOrg -TeamSlug $sourceTeam.slug
        foreach ($member in $teamMembers | Where-Object { -not [string]::IsNullOrWhiteSpace($_.login) }) {
            $mappedUser = $userMapping | Where-Object { $_.SourceUsername -eq $member.login }
            if ($mappedUser -and -not [string]::IsNullOrWhiteSpace($mappedUser.TargetUsername)) {
                $targetUsername = $mappedUser.TargetUsername
                Write-Output "Adding user '${targetUsername}' to team '$($targetTeam.name)'."
                Add-TeamMember -Org $TargetOrg -TeamSlug $targetTeam.slug -Username $targetUsername -Role ($member.role ?? "member")
            } else {
                Write-Warning "No mapping found for user '$($member.login)' in team '$($sourceTeam.name)'."
            }
        }
    } else {
        Write-Warning "Team '$($sourceTeam.name)' not found in target organization for member assignment."
    }
}

Write-Output "GitHub Teams migration completed."
