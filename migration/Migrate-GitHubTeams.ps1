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
    Write-Output "Retrieving teams from organization $Org..."
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
            Write-Error "Error retrieving teams from organization $Org (page $page): $_"
            break
        }
    } while ($true)
    Write-Output "Total teams found in $Org: $($teams.Count)"
    return $teams
}

function Get-TeamByName([string]$Org, [string]$Name) {
    Write-Output "Looking for team with name '$Name' in organization $Org..."
    $teams = Get-Teams -Org $Org
    $matchingTeam = $teams | Where-Object { $_.name -eq $Name }
    if ($matchingTeam) {
        Write-Output "Found team: $($matchingTeam.name) (slug: $($matchingTeam.slug))"
        return $matchingTeam
    } else {
        Write-Output "No team found with name '$Name' in organization $Org."
        return $null
    }
}

function Create-Team([string]$Org, [string]$Name, [string]$Description, [string]$Privacy, [string]$ParentTeamSlug) {
    if ($DryRun) {
        Write-Output "Dry-run: Would create team '$Name' in organization '$Org'."
        return
    }

    Write-Output "Creating team '$Name' in organization '$Org'..."
    
    $body = @{
        name        = $Name
        description = $Description
        privacy     = $Privacy.ToLower() # Ensure lowercase for API
    }
    
    if ($ParentTeamSlug) {
        $parentTeam = gh api "orgs/$Org/teams/$ParentTeamSlug" --jq '.' 2>$null | ConvertFrom-Json
        if ($parentTeam -and $parentTeam.id) {
            Write-Output "Found parent team with ID: $($parentTeam.id)"
            $body.parent_team_id = $parentTeam.id
        } else {
            Write-Warning "Parent team with slug '$ParentTeamSlug' not found. Creating '$Name' without parent."
        }
    }
    
    $jsonBody = $body | ConvertTo-Json -Depth 5
    Write-Output "API Request Body: $jsonBody"

    try {
        # Try to create the team and capture the full response for debugging
        $response = gh api --method POST "orgs/$Org/teams" --input - --raw-field name="$Name" --raw-field description="$Description" --raw-field privacy="closed" 2>&1
        Write-Output "API Response: $response"
        
        if ($response -match "already exists") {
            Write-Warning "Team '$Name' already exists in organization '$Org'."
        }
        
        # Verify the team was created by looking it up
        Start-Sleep -Seconds 2  # Brief pause to allow API propagation
        $createdTeam = Get-TeamByName -Org $Org -Name $Name
        if ($createdTeam) {
            Write-Output "Successfully created team '$Name' with slug '$($createdTeam.slug)'."
            return $createdTeam
        } else {
            Write-Warning "Team creation seemed successful but unable to retrieve the new team."
            return $null
        }
    }
    catch {
        Write-Warning "Failed to create team '$Name' in '$Org': $_"
        Write-Output "Full error: $($Error[0])"
        return $null
    }
}

function Get-TeamRepos([string]$Org, [string]$TeamSlug) {
    $repos = @()
    $page = 1
    do {
        $output = gh api "orgs/$Org/teams/$TeamSlug/repos?per_page=100&page=$page" --jq '.' 2>$null | ConvertFrom-Json
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
        $output = gh api "orgs/$Org/repos?per_page=100&page=$page" --jq '.' 2>$null | ConvertFrom-Json
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
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" --raw-field permission="$Permission"
        Write-Output "Set permission '$Permission' for team '$TeamSlug' on repository '$RepoName'."
    } catch {
        Write-Warning "Failed to set permission '$Permission' for team '$TeamSlug' on repository '$RepoName': $_"
    }
}

function Get-TeamMembers([string]$Org, [string]$TeamSlug) {
    $members = @()
    $page = 1
    do {
        $output = gh api "orgs/$Org/teams/$TeamSlug/members?per_page=100&page=$page" --jq '.' 2>$null | ConvertFrom-Json
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
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/memberships/$Username" --raw-field role="$Role"
        Write-Output "Added user '$Username' to team '$TeamSlug' with role '$Role'."
    } catch {
        Write-Warning "Failed to add user '$Username' to team '$TeamSlug': $_"
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

# First, check current teams in target org
Write-Output "Checking existing teams in target organization..."
$existingTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Found $($existingTargetTeams.Count) existing teams in target organization."

# Store created/matched teams for later use
$processedTeams = @{}

# First, create all parent teams (teams without parent)
Write-Output "Creating parent teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { -not $_.parent }) {
    Write-Output "Processing team: $($team.name)"
    $existingTeam = $existingTargetTeams | Where-Object { $_.name -eq $team.name }
    
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization."
        $processedTeams[$team.name] = $existingTeam
    } else {
        Write-Output "Creating team '$($team.name)' in target organization."
        $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
        if ($result) {
            $processedTeams[$team.name] = $result
        }
    }
}

# Wait a moment to ensure all parent teams are created before proceeding
Start-Sleep -Seconds 5

# Refresh the list of target teams
$targetTeams = Get-Teams -Org $TargetOrg
Write-Output "After creating parent teams: $($targetTeams.Count) teams in target organization."

# Then create child teams
Write-Output "Creating child teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { $_.parent }) {
    Write-Output "Processing child team: $($team.name)"
    $existingTeam = $targetTeams | Where-Object { $_.name -eq $team.name }
    
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization."
        $processedTeams[$team.name] = $existingTeam
    } else {
        # Find the parent team in the target org
        $parentTeamName = $team.parent.name
        $parentTeam = $targetTeams | Where-Object { $_.name -eq $parentTeamName }
        
        if ($parentTeam) {
            Write-Output "Creating child team '$($team.name)' under parent '$parentTeamName' in target organization."
            $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy -ParentTeamSlug $parentTeam.slug
            if ($result) {
                $processedTeams[$team.name] = $result
            }
        } else {
            Write-Output "Parent team '$parentTeamName' not found in target organization. Creating '$($team.name)' without parent."
            $result = Create-Team -Org $TargetOrg -Name $team.name -Description $team.description -Privacy $team.privacy
            if ($result) {
                $processedTeams[$team.name] = $result
            }
        }
    }
}

# Refresh the list of target teams again
Start-Sleep -Seconds 5  # Allow time for API changes to propagate
$finalTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Final count after creating all teams: $($finalTargetTeams.Count) teams in target organization."
Write-Output "Teams in target organization:"
$finalTargetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

# 4. For each team, assign repository permissions
Write-Output "Setting repository permissions for teams..."
$targetRepos = Get-Repos -Org $TargetOrg

foreach ($sourceTeam in $sourceTeams) {
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    
    if ($targetTeam) {
        Write-Output "Setting permissions for team: $($targetTeam.name) (slug: $($targetTeam.slug))"
        $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeam.slug
        
        foreach ($repo in $teamRepos) {
            # Check if the repository exists in the target organization
            $targetRepo = $targetRepos | Where-Object { $_.name -eq $repo.name }
            
            if ($targetRepo) {
                $permission = if ($repo.role_name) { $repo.role_name } else { "pull" } # Default to "pull" if role_name is not set
                Write-Output "Setting permission '$permission' for team '$($targetTeam.name)' on repository '$($targetRepo.name)'."
                Set-TeamRepoPermission -Org $TargetOrg -TeamSlug $targetTeam.slug -RepoName $targetRepo.name -Permission $permission
            } else {
                Write-Output "Repository '$($repo.name)' not found in target organization. Skipping permission assignment."
            }
        }
    } else {
        Write-Warning "Team '$($sourceTeam.name)' not found in target organization for permission setting."
    }
}

# 5. Add team members using the user mapping
Write-Output "Adding team members using user mapping from $UserMappingCsv..."
try {
    $userMapping = Get-UserMapping -CsvPath $UserMappingCsv
    Write-Output "Loaded user mapping with $($userMapping.Count) entries."
} catch {
    Write-Warning "Failed to load user mapping: $_"
    $userMapping = @()
}

foreach ($sourceTeam in $sourceTeams) {
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    
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
    } else {
        Write-Warning "Team '$($sourceTeam.name)' not found in target organization for member assignment."
    }
}

Write-Output "GitHub Teams migration completed."
