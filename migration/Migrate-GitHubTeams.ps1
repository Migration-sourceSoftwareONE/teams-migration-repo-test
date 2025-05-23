param (
    [string]$SourceOrg,
    [string]$TargetOrg,
    [string]$UserMappingCsv,
    [string]$SourcePAT,
    [string]$TargetPAT
)

# Load user mappings from CSV
$userMappings = Import-Csv -Path $UserMappingCsv

# Hashtable to map source team slug -> target team slug
$newTeams = @{}

function Get-MappedUserEmail([string]$sourceUsername) {
    $mapping = $userMappings | Where-Object { $_.'SourceUsername' -eq $sourceUsername }
    if ($mapping) { return $mapping.Email }
    return $null
}

# Placeholder functions (you should implement these or import them from your module)
function Create-Team {
    param($Org, $Name, $Description, $Privacy, $ParentTeamSlug)
    # Implement actual team creation via GitHub CLI or API and return created team object with 'slug' property
}

function Get-TeamRepos {
    param($Org, $TeamSlug)
    # Implement actual repo list retrieval for team
}

function Set-TeamRepoPermission {
    param($Org, $TeamSlug, $RepoName, $Permission)
    # Implement setting team permissions on repo
}

function Get-TeamMembers {
    param($Org, $TeamSlug)
    # Implement getting team members usernames
}

function Add-TeamMember {
    param($Org, $TeamSlug, $MemberEmail)
    # Implement adding member to team by email (or username)
}

# Get source and target teams
$sourceTeams = gh api "orgs/$SourceOrg/teams" --header "Authorization: Bearer $SourcePAT" | ConvertFrom-Json
$targetTeams = gh api "orgs/$TargetOrg/teams" --header "Authorization: Bearer $TargetPAT" | ConvertFrom-Json

# Get target repos list (to check permissions assignment)
$targetRepos = gh api "orgs/$TargetOrg/repos" --header "Authorization: Bearer $TargetPAT" | ConvertFrom-Json

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

# Apply repo permissions for each team, skip if no repos assigned
foreach ($team in $sourceTeams) {
    $sourceTeamSlug = $team.slug
    if (-not $newTeams.ContainsKey($sourceTeamSlug)) { continue }

    $targetTeamSlug = $newTeams[$sourceTeamSlug]
    $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeamSlug

    if (-not $teamRepos -or $teamRepos.Count -eq 0) {
        Write-Output "Team '$($team.name)' has no repos assigned, skipping permission assignment."
        continue
    }

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

# Migrate team members
foreach ($team in $sourceTeams) {
    $sourceTeamSlug = $team.slug
    if (-not $newTeams.ContainsKey($sourceTeamSlug)) { continue }

    $targetTeamSlug = $newTeams[$sourceTeamSlug]
    $members = Get-TeamMembers -Org $SourceOrg -TeamSlug $sourceTeamSlug

    foreach ($memberUsername in $members) {
        $mappedEmail = Get-MappedUserEmail -sourceUsername $memberUsername
        if (-not $mappedEmail) {
            Write-Warning "No email mapping found for user $memberUsername, skipping adding to team $($team.name)."
            continue
        }

        Add-TeamMember -Org $TargetOrg -TeamSlug $targetTeamSlug -MemberEmail $mappedEmail
        Write-Output "Added member $mappedEmail to team $($team.name)"
    }
}

Write-Output "Migration completed."
