param (
    [Parameter(Mandatory = $true)] [string] $SourceOrg,
    [Parameter(Mandatory = $true)] [string] $TargetOrg,
    [Parameter(Mandatory = $true)] [string] $UserMappingCsv,
    [Parameter(Mandatory = $true)] [string] $SourcePAT,
    [Parameter(Mandatory = $true)] [string] $TargetPAT
)

# Authenticate GH CLI for source and target orgs
function Set-GHAuth($Token) {
    gh auth login --with-token <<< $Token | Out-Null
}

Write-Output "Authenticating to source org..."
Set-GHAuth $SourcePAT
Write-Output "Authenticated to source org."

Write-Output "Authenticating to target org..."
Set-GHAuth $TargetPAT
Write-Output "Authenticated to target org."

# Load user mappings CSV: columns SourceUsername,Email
$userMappings = Import-Csv $UserMappingCsv

function Get-MappedUserEmail([string]$sourceUsername) {
    $mapping = $userMappings | Where-Object { $_.'SourceUsername' -eq $sourceUsername }
    if ($mapping) { return $mapping.Email }
    return $null
}

function Run-GH($args) {
    $result = gh $args --json slug,name --jq '.' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gh command failed: gh $args`n$result"
        return $null
    }
    return $result | ConvertFrom-Json
}

function Get-SourceTeams {
    gh team list --org $SourceOrg --json slug,name,description,privacy,parent --limit 1000 | ConvertFrom-Json
}

function Get-TargetTeams {
    gh team list --org $TargetOrg --json slug,name,description,privacy,parent --limit 1000 | ConvertFrom-Json
}

function Create-Team {
    param (
        [string] $Org,
        [string] $Name,
        [string] $Description,
        [string] $Privacy,
        [string] $ParentTeamSlug
    )
    $args = @("team", "create", $Name, "--org", $Org)

    if ($Description) {
        $args += "--description"
        $args += $Description
    }
    if ($Privacy) {
        $args += "--privacy"
        $args += $Privacy
    }
    if ($ParentTeamSlug) {
        $args += "--parent-team-slug"
        $args += $ParentTeamSlug
    }

    $output = gh @args --json slug,name 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to create team '$Name': $output"
        return $null
    }
    return $output | ConvertFrom-Json
}

function Get-TeamRepos {
    param (
        [string] $Org,
        [string] $TeamSlug
    )
    $repos = gh api "orgs/$Org/teams/$TeamSlug/repos" --jq '.' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to get repos for team $TeamSlug in org $Org: $repos"
        return @()
    }
    return $repos | ConvertFrom-Json
}

function Get-TargetRepos {
    $repos = gh repo list $TargetOrg --json name --limit 1000 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to list repos in target org $TargetOrg: $repos"
        return @()
    }
    return $repos | ConvertFrom-Json
}

function Set-TeamRepoPermission {
    param (
        [string] $Org,
        [string] $TeamSlug,
        [string] $RepoName,
        [string] $Permission
    )
    $args = @("api", "--method", "PUT", "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName", "-f", "permission=$Permission")
    $result = gh @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to set permission '$Permission' on repo '$RepoName' for team '$TeamSlug': $result"
        return $false
    }
    return $true
}

function Get-TeamMembers {
    param (
        [string] $Org,
        [string] $TeamSlug
    )
    $members = gh api "orgs/$Org/teams/$TeamSlug/members" --jq '.' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to get members for team $TeamSlug in org $Org: $members"
        return @()
    }
    return $members | ConvertFrom-Json
}

function Add-TeamMember {
    param (
        [string] $Org,
        [string] $TeamSlug,
        [string] $UserEmail
    )
    # GitHub API adds member by username, so we must get username from email mapping
    if (-not $UserEmail) {
        Write-Warning "User email is null, cannot add member to team $TeamSlug"
        return $false
    }

    # We assume that user email equals username for now or you have to implement email-to-username mapping logic
    $username = $UserEmail.Split('@')[0]

    $args = @("api", "--method", "PUT", "orgs/$Org/teams/$TeamSlug/memberships/$username")
    $result = gh @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to add user $username to team $TeamSlug: $result"
        return $false
    }
    return $true
}

Write-Output "Loading source teams..."
$sourceTeams = Get-SourceTeams
if (-not $sourceTeams) {
    Write-Error "Failed to load source teams."
    exit 1
}

Write-Output "Loading target teams..."
$targetTeams = Get-TargetTeams
if (-not $targetTeams) {
    Write-Error "Failed to load target teams."
    exit 1
}

Write-Output "Loading target repositories..."
$targetRepos = Get-TargetRepos

$newTeams = @{}

# Create teams preserving hierarchy
foreach ($team in $sourceTeams) {
    if ($targetTeams.name -contains $team.name) {
        Write-Output "Skipping existing team: $($team.name)"
        $matched = $targetTeams | Where-Object { $_.name -eq $team.name }
        $newTeams[$team.slug] = $matched.slug
        continue
    }

    $parentTeamSlug = $null
    if ($team.parent -and $newTeams.ContainsKey($team.parent.slug)) {
        $parentTeamSlug = $newTeams[$team.parent.slug]
    }

    $createdTeam = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamSlug $parentTeamSlug
    if ($createdTeam) {
        Write-Output "Created team $($team.name)"
        $newTeams[$team.slug] = $createdTeam.sl
