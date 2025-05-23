param(
    [Parameter(Mandatory=$true)][string]$SourceOrg,
    [Parameter(Mandatory=$true)][string]$TargetOrg,
    [Parameter(Mandatory=$true)][string]$UserMappingCsv,
    [string]$SourcePAT = $null,
    [string]$TargetPAT = $null
)

function GhAuth([string]$Token) {
    if (-not $Token) {
        Write-Output "Using existing GitHub CLI authentication"
        return
    }

    # Use GH_TOKEN environment variable for non-interactive auth
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
        $pageData = gh api "orgs/$Org/teams?per_page=100&page=$page" 2>$null | ConvertFrom-Json
        if ($pageData) {
            $teams += $pageData
            $page++
        }
    } while ($pageData.Count -eq 100)
    return $teams
}

function Create-Team([string]$Org, [string]$Name, [string]$Description, [string]$Privacy, [string]$ParentTeamId) {
    $body = @{ name = $Name; description = $Description; privacy = $Privacy }
    if ($ParentTeamId) { $body.parent_team_id = $ParentTeamId }
    $json = $body | ConvertTo-Json
    try {
        $result = gh api --method POST "orgs/$Org/teams" --input - <<<$json 2>$null | ConvertFrom-Json
        return $result
    } catch {
        Write-Warning "Failed to create team $Name in $Org: $_"
        return $null
    }
}

function Get-Repos([string]$Org) {
    $repos = @()
    $page = 1
    do {
        $pageData = gh api "orgs/$Org/repos?per_page=100&page=$page" 2>$null | ConvertFrom-Json
        if ($pageData) {
            $repos += $pageData
            $page++
        }
    } while ($pageData.Count -eq 100)
    return $repos
}

function Get-TeamRepos([string]$Org, [string]$TeamSlug) {
    $repos = @()
    $page = 1
    do {
        $pageData = gh api "orgs/$Org/teams/$TeamSlug/repos?per_page=100&page=$page" 2>$null | ConvertFrom-Json
        if ($pageData) {
            $repos += $pageData
            $page++
        }
    } while ($pageData.Count -eq 100)
    return $repos
}

function Set-TeamRepoPermission([string]$Org, [string]$TeamSlug, [string]$Repo, [string]$Permission) {
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$Repo" -f permission=$Permission 2>$null
    } catch {
        Write-Warning "Failed to set $Permission for team $TeamSlug on repo $Repo in $Org: $_"
    }
}

# Authenticate to both orgs
Write-Output "Authenticating to source org..."
GhAuth $SourcePAT
Write-Output "Authenticating to target org..."
GhAuth $TargetPAT

# Load data
$userMap = Import-Csv $UserMappingCsv
$sourceTeams = Get-Teams -Org $SourceOrg
$targetTeams = Get-Teams -Org $TargetOrg
$targetRepos = Get-Repos -Org $TargetOrg

# Map existing target teams: name -> slug
$targetTeamMap = @{}
foreach ($t in $targetTeams) { $targetTeamMap[$t.name] = $t.slug }

# Track new and existing team slugs
$newTeams = @{}

# Create or use existing teams
foreach ($team in $sourceTeams) {
    if ($targetTeamMap.ContainsKey($team.name)) {
        Write-Output "Skipping existing team: $($team.name)"
        $newTeams[$team.slug] = $targetTeamMap[$team.name]
        continue
    }
    # Determine parent ID if needed
    $parentId = $null
    if ($team.parent -and $newTeams.ContainsKey($team.parent.slug)) {
        $parentId = $newTeams[$team.parent.slug]
    }
    $created = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamId $parentId
    if ($created) {
        $newTeams[$team.slug] = $created.slug
        Write-Output "Created team: $($team.name)"
    }
}

# Assign repo permissions
foreach ($team in $sourceTeams) {
    if (-not $newTeams.ContainsKey($team.slug)) { continue }
    $slug = $newTeams[$team.slug]
    $repos = Get-TeamRepos -Org $SourceOrg -TeamSlug $team.slug

    foreach ($repo in $repos) {
        if ($targetRepos.name -contains $repo.name) {
            # Determine permission (read/write/etc.)
            $perm = ($repo.permissions.PSObject.Properties | Where-Object { $_.Value -eq $true }).Name
            Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $slug -Repo $repo.name -Permission $perm
            Write-Output "Set $perm on $($repo.name) for team $($team.name)"
        } else {
            Write-Warning "Skipping missing repo $($repo.name) for team $($team.name)"
        }
    }
}

Write-Output "Migration completed."
