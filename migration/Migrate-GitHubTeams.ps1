param(
    [Parameter(Mandatory=$true)][string]$SourceOrg,
    [Parameter(Mandatory=$true)][string]$TargetOrg,
    [Parameter(Mandatory=$true)][string]$UserMappingCsv,
    [switch]$DryRun
)

function GhAuth([string]$EnvVarName) {
    $Token = (Get-Item "env:$EnvVarName").Value
    if (-not $Token) {
        Write-Error "Environment variable $EnvVarName is not set or empty."
        exit 1
    }

    $env:GH_TOKEN = $Token

    $authResult = gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "GitHub CLI authentication failed using $EnvVarName."
        exit 1
    } else {
        Write-Output "GitHub CLI authenticated using $EnvVarName."
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
    if ($DryRun) {
        Write-Output "Dry-run: Would create team '$Name' in organization '$Org'."
        return
    }

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
    if ($DryRun) {
        Write-Output "Dry-run: Would set permission '$Permission' for team '$TeamSlug' on repository '$RepoName'."
        return
    }

    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" -f permission=$Permission
        Write-Output "Set permission '$Permission' for team '$TeamSlug' on repository '$RepoName'."
    } catch {
        Write-Warning ("Failed to set permission {0} for team {1} on repository {2}: {3}" -f $Permission, $TeamSlug, $RepoName, $_)
    }
}

function Get-TeamMembers([string]$Org, [string]$TeamSlug) {
    $members = @()
    $page = 1
    do {
        $output = gh api "orgs/$Org/teams/$TeamSlug/members?per_page=100&page=$page" -q '.' 2>$null | ConvertFrom-Json
        if ($output) {
            $members += $output
            $page++
        }
    } while ($output.Count -eq 100)
    return $members
}

function Add-TeamMember([string]$Org, [string]$TeamSlug, [string]$Username, [string]$Role = "member") {
    if ($DryRun) {
        Write-Output "Dry-run: Would add user '$Username' to team '$TeamSlug' with role '$Role'."
        return
    }
    
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/memberships/$Username" -f role=$Role
        Write-Output "Added user '$Username' to team '$TeamSlug' with role '$Role'."
    } catch {
        Write-Warning ("Failed to add user {0} to team {1}: {2}" -f $Username, $TeamSlug, $_)
    }
}

function Get-UserMapping([string]$CsvPath) {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "User mapping CSV file not found at path: $CsvPath"
        exit 1
    }
    
    try {
        $userMap = Import-Csv -Path $CsvPath
        return $userMap
    } catch {
        Write-Error "Failed to read user mapping CSV: $_"
        exit 1
    }
}

# Main execution starts here
Write-Output "Starting GitHub Teams migration from '$SourceOrg' to '$TargetOrg'"

# Check if the user mapping file exists
if (-not (Test-Path $UserMappingCsv)) {
    Write-Error "User mapping file not found: $UserMappingCsv"
    exit 1
}

# 1. Authenticate for source organization operations
Write-Output "Authenticating with source organization..."
GhAuth "SOURCE_PAT"

# 2. Get all teams from the source organization
Write-Output "Fetching teams from source organization '$SourceOrg'..."
$sourceTeams = Get-Teams -Org $SourceOrg
Write-Output "Found $($sourceTeams.Count) teams in source organization."

# 3. Create teams in the target organization (respecting parent-child relationships)
Write-Output "Authenticating with target organization..."
GhAuth "TARGET_PAT"

# First, create all parent teams (teams without parent)
Write-Output "Creating parent teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { -not $_.parent }) {
    Write-Output "Processing team: $($team.name)"
    $existingTeam = Get-TeamByName -Org $TargetOrg -Name $team.name
    
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization."
    } else {
        Write-Output "Creating team '$($team.name)' in target organization."
        $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
    }
}

# Then create child teams
Write-Output "Creating child teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { $_.parent }) {
    Write-Output "Processing child team: $($team.name)"
    $existingTeam = Get-TeamByName -Org $TargetOrg -Name $team.name
    
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization."
    } else {
        # Find the parent team in the target org
        $parentTeam = Get-TeamByName -Org $TargetOrg -Name $team.parent.name
        
        if ($parentTeam) {
            Write-Output "Creating child team '$($team.name)' under parent '$($team.parent.name)' in target organization."
            $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamSlug $parentTeam.slug
        } else {
            Write-Output "Parent team '$($team.parent.name)' not found in target organization. Creating '$($team.name)' without parent."
            $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
        }
    }
}

# 4. For each team, assign repository permissions
Write-Output "Setting repository permissions for teams..."
$targetRepos = Get-Repos -Org $TargetOrg
$targetTeams = Get-Teams -Org $TargetOrg

foreach ($sourceTeam in $sourceTeams) {
    $targetTeam = $targetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    
    if ($targetTeam) {
        Write-Output "Setting permissions for team: $($targetTeam.name)"
        $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeam.slug
        
        foreach ($repo in $teamRepos) {
            # Check if the repository exists in the target organization
            $targetRepo = $targetRepos | Where-Object { $_.name -eq $repo.name }
            
            if ($targetRepo) {
                Write-Output "Setting permission '$($repo.role_name)' for team '$($targetTeam.name)' on repository '$($targetRepo.name)'."
                Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $targetTeam.slug -RepoName $targetRepo.name -Permission $repo.role_name
            } else {
                Write-Output "Repository '$($repo.name)' not found in target organization. Skipping permission assignment."
            }
        }
    } else {
        Write-Warning "Team '$($sourceTeam.name)' not found in target organization."
    }
}

# 5. Add team members using the user mapping
Write-Output "Adding team members using user mapping from $UserMappingCsv..."
$userMapping = Get-UserMapping -CsvPath $UserMappingCsv

foreach ($sourceTeam in $sourceTeams) {
    $targetTeam = $targetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    
    if ($targetTeam) {
        Write-Output "Processing members for team: $($targetTeam.name)"
        $teamMembers = Get-TeamMembers -Org $SourceOrg -TeamSlug $sourceTeam.slug
        
        foreach ($member in $teamMembers) {
            # Find the mapped username for this user
            $mappedUser = $userMapping | Where-Object { $_.SourceUsername -eq $member.login }
            
            if ($mappedUser) {
                $targetUsername = $mappedUser.TargetUsername
                Write-Output "Adding user '$targetUsername' to team '$($targetTeam.name)'."
                Add-TeamMember -Org $TargetOrg -TeamSlug $targetTeam.slug -Username $targetUsername -Role $member.role
            } else {
                Write-Warning "No mapping found for user '$($member.login)' in team '$($sourceTeam.name)'."
            }
        }
    }
}

Write-Output "GitHub Teams migration completed."
