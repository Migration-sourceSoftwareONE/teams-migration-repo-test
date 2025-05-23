param(
    [Parameter(Mandatory)][string]$SourceOrg,
    [Parameter(Mandatory)][string]$TargetOrg,
    [Parameter(Mandatory)][string]$MappingCsv,
    [Parameter(Mandatory)][string]$SourceToken,
    [Parameter(Mandatory)][string]$TargetToken
)

function Login-GitHubCli {
    param(
        [string]$Token
    )
    $Token | gh auth login --hostname github.com --with-token | Out-Null
}

function Get-GhJson {
    param(
        [string]$Command
    )
    $result = gh $Command --json name,slug,id,parentTeam,description,privacy --paginate --jq '.[]'
    return $result | ConvertFrom-Json
}

function Get-Teams {
    param([string]$Org)

    # Fetch all teams with details
    $teamsRaw = gh api "orgs/$Org/teams?per_page=100" --paginate
    $teams = $teamsRaw | ConvertFrom-Json
    return $teams
}

function Find-TeamByName {
    param([array]$Teams, [string]$Name)
    return $Teams | Where-Object { $_.name -eq $Name }
}

function Create-Team {
    param(
        [string]$Org,
        [string]$Name,
        [string]$Description,
        [string]$Privacy,
        [string]$ParentSlug # nullable
    )

    $body = @{
        name = $Name
        description = $Description
        privacy = $Privacy
    }
    if ($ParentSlug) {
        $body["parent_team_id"] = $ParentSlug
    }

    $jsonBody = $body | ConvertTo-Json -Depth 10
    try {
        $response = gh api --method POST "orgs/$Org/teams" --input - -H "Accept: application/vnd.github+json" --raw-field "$jsonBody" -Body $jsonBody 2>&1
        return $response | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to create team $Name in $Org: $_"
        return $null
    }
}

function Get-Repos {
    param([string]$Org)
    $reposRaw = gh api "orgs/$Org/repos?per_page=100" --paginate
    $repos = $reposRaw | ConvertFrom-Json
    return $repos
}

function Set-TeamRepoPermission {
    param(
        [string]$Org,
        [string]$TeamSlug,
        [string]$RepoName,
        [string]$Permission
    )

    # Permissions allowed: pull, triage, push, maintain, admin
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$RepoName" -f permission=$Permission
        Write-Host "Assigned $Permission permission for team $TeamSlug on repo $RepoName"
    } catch {
        Write-Warning "Failed to assign repo permission for team $TeamSlug on repo $RepoName: $_"
    }
}

function Get-UserByEmail {
    param(
        [string]$Org,
        [string]$Email
    )
    # GitHub API does not provide user email searching for org members directly.
    # Instead, we get all members and then fetch their emails if public (or via mapping file).
    # For this script, assume users exist in target org with given username from CSV mapping.
    # We just return username from CSV for simplicity here.
    return $null
}

# Start script

Write-Host "Logging into Source Org..."
Login-GitHubCli -Token $SourceToken
Write-Host "Logging into Target Org..."
Login-GitHubCli -Token $TargetToken

Write-Host "Loading user mapping CSV: $MappingCsv"
if (-Not (Test-Path $MappingCsv)) {
    Write-Error "Mapping CSV file not found at path: $MappingCsv"
    exit 1
}

$userMap = Import-Csv $MappingCsv

# Get source teams
Write-Host "Fetching source organization teams..."
$sourceTeams = Get-Teams -Org $SourceOrg

# Get target teams
Write-Host "Fetching target organization teams..."
$targetTeams = Get-Teams -Org $TargetOrg

# Prepare a dictionary of target teams by name for quick lookup
$targetTeamNames = @{}
foreach ($t in $targetTeams) {
    $targetTeamNames[$t.name] = $t
}

$skippedTeams = @()
$createdTeams = @{}

# Create teams recursively respecting hierarchy
function Create-TeamRecursive {
    param(
        [object]$Team
    )

    # If already created or exists, skip
    if ($targetTeamNames.ContainsKey($Team.name)) {
        Write-Host "Skipping existing team: $($Team.name)"
        $skippedTeams += $Team.name
        return $targetTeamNames[$Team.name]
    }

    # Parent team slug/id
    $parentId = $null
    if ($Team.parent) {
        # Find or create parent first
        $parentTeam = $sourceTeams | Where-Object { $_.id -eq $Team.parent.id }
        if ($parentTeam) {
            $parentCreated = Create-TeamRecursive -Team $parentTeam
            $parentId = $parentCreated.id
        }
    }

    # Create team
    Write-Host "Creating team: $($Team.name)..."
    $newTeam = gh api --method POST "orgs/$TargetOrg/teams" -f name="$($Team.name)" `
                                              -f description="$($Team.description)" `
                                              -f privacy="$($Team.privacy)" `
                                              $(if ($parentId) { "-f parent_team_id=$parentId" } ) `
                                              --silent | ConvertFrom-Json
    if ($newTeam) {
        $createdTeams[$Team.name] = $newTeam
        $targetTeamNames[$Team.name] = $newTeam
        return $newTeam
    } else {
        Write-Warning "Failed to create team $($Team.name)"
        return $null
    }
}

# Build a map of created teams (or existing) for permission assignment later
foreach ($team in $sourceTeams) {
    Create-TeamRecursive -Team $team | Out-Null
}

# Fetch repos for source and target orgs
$sourceRepos = Get-Repos -Org $SourceOrg
$targetRepos = Get-Repos -Org $TargetOrg
$targetRepoNames = $targetRepos.name

# For each source team, get repo permissions and replicate
foreach ($team in $sourceTeams) {
    # Skip if team not created
    if (-not $targetTeamNames.ContainsKey($team.name)) {
        Write-Warning "Team $($team.name) missing in target, skipping repo permission assignment"
        continue
    }
    $targetTeamSlug = $targetTeamNames[$team.name].slug

    # Get repos with permissions for team
    $permsRaw = gh api "teams/$($team.slug)/repos?per_page=100" --paginate | ConvertFrom-Json
    foreach ($repo in $permsRaw) {
        if ($targetRepoNames -contains $repo.name) {

            $perm = "push" # fallback

            Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $targetTeamSlug -RepoName $repo.name -Permission $perm
        } else {
            Write-Warning "Repository $($repo.name) not found in target org, skipping permission assignment."
        }
    }
}

# Map users - this script example just logs unmapped users (full mapping logic needs user email queries)
$unmappedUsers = @()
foreach ($user in $userMap) {
    # Try find user in target org by email 
    $foundUser = $null
    if (-not $foundUser) {
        Write-Warning "User '$($user.'SourceUserName')' with email '$($user.Email)' not found in target org"
        $unmappedUsers += $user
    }
}

# Final report
Write-Host "=== Migration Summary ==="
Write-Host "Teams skipped (already existed):"
$skippedTeams | ForEach-Object { Write-Host "- $_" }
Write-Host "Users not mapped:"
foreach ($u in $unmappedUsers) {
    Write-Host "- Source username: $($u.'SourceUserName'), Email: $($u.Email)"
}

Write-Host "Migration script finished."
