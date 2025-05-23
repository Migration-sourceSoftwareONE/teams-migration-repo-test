param(
    [Parameter(Mandatory=$true)][string]$SourcePAT,
    [Parameter(Mandatory=$true)][string]$TargetPAT,
    [Parameter(Mandatory=$true)][string]$SourceOrg,
    [Parameter(Mandatory=$true)][string]$TargetOrg,
    [Parameter(Mandatory=$true)][string]$UserMappingCsv
)

function GhAuth([string]$Token) {
    if (-not $Token) {
        Write-Output "Using existing GitHub CLI authentication"
        return
    }

    $env:GH_TOKEN = $Token

    $authResult = gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "GitHub CLI authentication failed with provided token."
        exit 1
    } else {
        Write-Output "GitHub CLI authenticated using GH_TOKEN."
    }
}

function Get-Teams([string]$Org) {
    $teams = @()
    $page = 1
    do {
        $output = gh api "orgs/$Org/teams?per_page=100&page=$page" -q '.' 2>$null | ConvertFrom-Json
        if ($output) {
            $teams += $output
            $page++
        }
    } while ($output.Count -eq 100)
    return $teams
}

function Get-TeamByName([string]$Org, [string]$Name) {
    $teams = Get-Teams -Org $Org
    return $teams | Where-Object { $_.name -eq $Name }
}

function Create-Team([string]$Org, [string]$Name, [string]$Description, [string]$Privacy, [string]$ParentTeamSlug) {
    $body = @{
        name        = $Name
        description = $Description
        privacy     = $Privacy
    }
    if ($ParentTeamSlug) {
        $body.parent_team_id = $ParentTeamSlug
    }
    $jsonBody = $body | ConvertTo-Json -Depth 5

    try {
        $result = gh api --method POST "orgs/$Org/teams" -f body="$jsonBody" 2>$null | ConvertFrom-Json
        return $result
    }
    catch {
        Write-Warning ("Failed to create team {0} in {1}: {2}" -f $Name, $Org, $_)
        return $null
    }
}

function Get-TeamRepos([string]$Org, [string]$TeamSlug) {
    $repos = @()
    $page = 1
    do {
        $output = gh api "orgs/$Org/teams/$TeamSlug/repos?per_page=100&page=$page" -q '.' 2>$null | ConvertFrom-Json
        if ($output) {
            $repos += $output
            $page++
        }
    } while ($output.Count -eq 100)
    return $repos
}

function Get-Repos([string]$Org) {
    $repos = @()
    $page = 1
    do {
        $output = gh api "orgs/$Org/repos?per_page=100&page=$page" -q '.' 2>$null | ConvertFrom-Json
        if ($output) {
            $repos += $output
            $page++
        }
    } while ($output.Count -eq 100)
    return $repos
}

function Set-TeamRepoPermission([string]$Org, [string]$TeamSlug, [string]$RepoName, [string]$Permission) {
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" -f permission="$Permission" 2>$null | Out-Null
    }
    catch {
        Write-Warning ("Failed to set permission {0} for team {1} on repo {2} in {3}: {4}" -f $Permission, $TeamSlug, $RepoName, $Org, $_)
    }
}

# Authenticate to source org
Write-Output "Authenticating to source org..."
GhAuth $SourcePAT
Write-Output "Authenticated to source org."

# Get source teams
$sourceTeams = Get-Teams -Org $SourceOrg

# Load user mapping CSV
$userMappings = Import-Csv $UserMappingCsv

# Authenticate to target org
Write-Output "Authenticating to target org..."
GhAuth $TargetPAT
Write-Output "Authenticated to target org."

# Get target teams and repos
$targetTeams = Get-Teams -Org $TargetOrg
$targetRepos = Get-Repos -Org $TargetOrg

# Hashtable for new teams created
$newTeams = @{}

# Function to find mapped user by source username
function Get-MappedUserEmail([string]$sourceUsername) {
    $mapping = $userMappings | Where-Object { $_.'SourceUsername' -eq $sourceUsername }
    if ($mapping) { return $mapping.Email }
    return $null
}

# Create teams preserving hierarchy
foreach ($team in $sourceTeams) {
    if ($targetTeams.Name -contains $team.name) {
        Write-Output "Skipping existing team: $($team.name)"
        $newTeams[$team.slug] = ($targetTeams | Where-Object { $_.name -eq $team.name }).slug
        continue
    }

    $parentTeamSlug = $null
    if ($team.parent -and $newTeams.ContainsKey($team.parent.slug)) {
        $parentTeamSlug = $newTeams[$team.parent.slug]
    }

    $createdTeam = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamSlug $parentTeamSlug
    if ($createdTeam) {
        Write-Output "Created team $($team.name)"
        $newTeams[$team.slug] = $createdTeam.slug
    } else {
        Write-Warning "Failed to create team $($team.name)"
    }
}

# Apply repo permissions for each team
foreach ($team in $sourceTeams) {
    $sourceTeamSlug = $team.slug
    if (-not $newTeams.ContainsKey($sourceTeamSlug)) { continue }

    $targetTeamSlug = $newTeams[$sourceTeamSlug]
    $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeamSlug

    foreach ($repo in $teamRepos) {
        if (-not ($targetRepos.Name -contains $repo.name)) {
            Write-Warning "Repo $($repo.name) from source not found in target, skipping permission assignment."
            continue
        }

        $permission = ($repo.permissions | Get-Member -MemberType NoteProperty).Name | Where-Object { $repo.permissions.$_ -eq $true }
        if ($permission) {
            Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $targetTeamSlug -RepoName $repo.name -Permission $permission
            Write-Output "Set permission on repo $($repo.name) for team $($team.name)"
        }
    }
}

Write-Output "Migration completed."
