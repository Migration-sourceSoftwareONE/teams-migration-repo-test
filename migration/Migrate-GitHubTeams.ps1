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
    
    # Filter out any teams with empty names
    $validTeams = $teams | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }
    
    if ($teams.Count -ne $validTeams.Count) {
        Write-Warning "Filtered out $($teams.Count - $validTeams.Count) teams with empty names."
    }
    
    Write-Output "Total valid teams found in ${Org}: $($validTeams.Count)"
    return $validTeams
}

function Get-TeamByName([string]$Org, [string]$Name) {
    # Skip lookup for empty names
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
    # Validate team name
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Warning "Cannot create a team with an empty name in organization '${Org}'."
        return $null
    }

    if ($DryRun) {
        Write-Output "Dry-run: Would create team '${Name}' in organization '${Org}'."
        return
    }

    Write-Output "Creating team '${Name}' in organization '${Org}'..."
    
    # Use default privacy if not provided
    if ([string]::IsNullOrWhiteSpace($Privacy)) {
        $Privacy = "closed"
        Write-Output "Using default privacy setting: closed"
    }
    
    # Sanitize description to prevent API errors
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = "Team $Name"
    }
    
    try {
        # Format JSON request body manually
        $jsonBody = @{
            name = $Name
            description = $Description
            privacy = $Privacy.ToLower()
        } | ConvertTo-Json -Compress
        
        # If parent team is specified, find its ID
        if (-not [string]::IsNullOrWhiteSpace($ParentTeamSlug)) {
            $parentTeam = gh api "orgs/$Org/teams/$ParentTeamSlug" --jq '.' 2>$null | ConvertFrom-Json
            if ($parentTeam -and $parentTeam.id) {
                Write-Output "Found parent team '${ParentTeamSlug}' with ID: $($parentTeam.id)"
                
                # Create new JSON with parent_team_id
                $jsonBodyObj = $jsonBody | ConvertFrom-Json
                $jsonBodyObj | Add-Member -Name "parent_team_id" -Value $parentTeam.id -MemberType NoteProperty
                $jsonBody = $jsonBodyObj | ConvertTo-Json -Compress
            } else {
                Write-Warning "Parent team '${ParentTeamSlug}' not found. Creating '${Name}' without parent."
            }
        }
        
        Write-Output "Team creation request body: $jsonBody"
        
        # Use the input stream to pass JSON directly
        $tempFile = New-TemporaryFile
        Set-Content -Path $tempFile.FullName -Value $jsonBody
        
        # Make the API call
        $response = gh api --method POST "orgs/$Org/teams" --input $tempFile.FullName
        Remove-Item -Path $tempFile.FullName
        
        # Check for successful creation by getting the created team
        Start-Sleep -Seconds 2 # Brief pause to allow API propagation
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

function Get-TeamRepoPermission([string]$Org, [string]$TeamSlug, [string]$RepoName) {
    if ([string]::IsNullOrWhiteSpace($TeamSlug) -or [string]::IsNullOrWhiteSpace($RepoName)) {
        Write-Warning "Cannot get permission with empty values: TeamSlug='${TeamSlug}', RepoName='${RepoName}'."
        return $null
    }
    
    try {
        $output = gh api "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" --jq '.permission' 2>$null
        if ($output) {
            $permission = $output.Trim('"')
            Write-Output "Team '${TeamSlug}' has permission '${permission}' on repository '${RepoName}'."
            return $permission
        }
    } catch {
        Write-Warning "Error getting permission for team '${TeamSlug}' on repository '${RepoName}': $_"
    }
    
    return $null
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
    # Validate parameters
    if ([string]::IsNullOrWhiteSpace($TeamSlug) -or [string]::IsNullOrWhiteSpace($RepoName)) {
        Write-Warning "Cannot set permission with empty values: TeamSlug='${TeamSlug}', RepoName='${RepoName}'."
        return
    }

    # Normalize permission to ensure it's a valid value
    $validPermissions = @("pull", "triage", "push", "maintain", "admin")
    $normalizedPermission = switch ($Permission.ToLower()) {
        "pull" { "pull" } # read
        "read" { "pull" }
        "triage" { "triage" }
        "push" { "push" } # write
        "write" { "push" }
        "maintain" { "maintain" }
        "admin" { "admin" }
        default { "pull" } # Default to read access if unrecognized
    }
    
    if ($normalizedPermission -ne $Permission) {
        Write-Output "Normalized permission '${Permission}' to '${normalizedPermission}'."
    }

    if ($DryRun) {
        Write-Output "Dry-run: Would set permission '${normalizedPermission}' for team '${TeamSlug}' on repository '${RepoName}'."
        return
    }

    Write-Output "Setting permission '${normalizedPermission}' for team '${TeamSlug}' on repository '${RepoName}'..."
    
    try {
        gh api --method PUT "orgs/$Org/teams/$TeamSlug/repos/$Org/$RepoName" --field permission="$normalizedPermission"
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Successfully set permission '${normalizedPermission}' for team '${TeamSlug}' on repository '${RepoName}'."
        } else {
            Write-Warning "Failed to set permission '${normalizedPermission}' for team '${TeamSlug}' on repository '${RepoName}'."
        }
    } catch {
        Write-Warning "Error setting permission '${normalizedPermission}' for team '${TeamSlug}' on repository '${RepoName}': $_"
    }
}

function Create-Repository([string]$Org, [string]$RepoName, [bool]$IsPrivate = $true) {
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        Write-Warning "Cannot create repository with empty name."
        return $null
    }
    
    if ($DryRun) {
        Write-Output "Dry-run: Would create repository '${RepoName}' in organization '${Org}'."
        return $null
    }
    
    Write-Output "Creating repository '${RepoName}' in organization '${Org}'..."
    
    try {
        $visibility = if ($IsPrivate) { "private" } else { "public" }
        $result = gh api --method POST "orgs/$Org/repos" --field name="$RepoName" --field private="$($IsPrivate.ToString().ToLower())" 2>$null | ConvertFrom-Json
        
        if ($result -and $result.name) {
            Write-Output "Successfully created repository '$($result.name)' in organization '${Org}'."
            return $result
        } else {
            Write-Warning "Failed to create repository '${RepoName}' in organization '${Org}'."
            return $null
        }
    } catch {
        Write-Warning "Error creating repository '${RepoName}' in organization '${Org}': $_"
        return $null
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
    
    # Filter out members with empty logins
    $validMembers = $members | Where-Object { -not [string]::IsNullOrWhiteSpace($_.login) }
    
    Write-Output "Total valid members for team '${TeamSlug}': $($validMembers.Count)"
    return $validMembers
}

function Add-TeamMember([string]$Org, [string]$TeamSlug, [string]$Username, [string]$Role = "member") {
    # Validate parameters
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

function Get-UserEmail([string]$Org, [string]$Username) {
    if ([string]::IsNullOrWhiteSpace($Username)) {
        Write-Warning "Cannot get email for user with empty username."
        return $null
    }
    
    try {
        # Note: This requires appropriate permissions to view user emails
        $output = gh api "users/$Username" --jq '.email' 2>$null
        if ($output -and $output -ne "null") {
            return $output.Trim('"')
        }
        
        # If public email not available, try to get from commits
        # This is a fallback and might not always work
        Write-Output "Public email not available for user '${Username}', attempting to find email from commits..."
        
        # Get repositories the user has contributed to in the org
        $repos = Get-Repos -Org $Org
        foreach ($repo in $repos) {
            $contributors = gh api "repos/$Org/$($repo.name)/contributors" --jq '.[].login' 2>$null
            if ($contributors -contains $Username) {
                # Look for commits by this user
                $commits = gh api "repos/$Org/$($repo.name)/commits?author=$Username&per_page=1" --jq '.[0].commit.author.email' 2>$null
                if ($commits -and $commits -ne "null") {
                    return $commits.Trim('"')
                }
            }
        }
    } catch {
        Write-Warning "Error retrieving email for user '${Username}': $_"
    }
    
    return $null
}

function Find-UserByEmail([string]$Org, [string]$Email) {
    if ([string]::IsNullOrWhiteSpace($Email)) {
        Write-Warning "Cannot find user with empty email."
        return $null
    }
    
    Write-Output "Searching for user with email '${Email}' in organization '${Org}'..."
    
    # This requires SAML SSO context for enterprise to be fully reliable
    # But we'll use some approximation methods that may work in many cases
    
    try {
        # Get all users in the organization
        $orgMembers = @()
        $page = 1
        
        do {
            $output = gh api "orgs/$Org/members?per_page=100&page=$page" --jq '.' 2>$null
            if ($output) {
                $outputJson = $output | ConvertFrom-Json
                if ($outputJson -and $outputJson.Count -gt 0) {
                    $orgMembers += $outputJson
                    $page++
                } else {
                    break
                }
            } else {
                break
            }
        } while ($true)
        
        Write-Output "Found $($orgMembers.Count) members in organization '${Org}'."
        
        # Create a cache for email lookups to avoid excessive API calls
        $emailCache = @{}
        
        # First try the most likely path - users with public emails
        foreach ($member in $orgMembers) {
            $userEmail = Get-UserEmail -Org $Org -Username $member.login
            if ($userEmail) {
                $emailCache[$member.login] = $userEmail
                if ($userEmail -eq $Email) {
                    Write-Output "Found user '$($member.login)' with matching email '${Email}'."
                    return $member.login
                }
            }
        }
    } catch {
        Write-Warning "Error searching for user by email '${Email}': $_"
    }
    
    Write-Warning "No user found with email '${Email}' in organization '${Org}'."
    return $null
}

function Get-UserMapping([string]$CsvPath) {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "User mapping CSV file not found at path: ${CsvPath}"
        exit 1
    }
    
    try {
        Write-Output "Reading user mapping from CSV file '${CsvPath}'..."
        $userMap = Import-Csv -Path $CsvPath
        
        # Validate the CSV has the required columns
        if ($userMap.Count -gt 0) {
            $firstRow = $userMap[0]
            
            # Check for source username and email columns
            $hasSourceUsername = $firstRow.PSObject.Properties.Name -contains "SourceUsername"
            $hasEmail = $firstRow.PSObject.Properties.Name -contains "Email"
            
            if (-not $hasSourceUsername -or -not $hasEmail) {
                Write-Warning "User mapping CSV does not contain required columns 'SourceUsername' and/or 'Email'."
                Write-Warning "Available columns: $($firstRow.PSObject.Properties.Name -join ', ')"
                
                # Try to infer column names
                $possibleSourceColumns = $firstRow.PSObject.Properties.Name | Where-Object { 
                    $_ -like "*Source*" -or $_ -like "*User*" -or $_ -like "*Login*" -or $_ -like "*Name*" 
                }
                
                $possibleEmailColumns = $firstRow.PSObject.Properties.Name | Where-Object { 
                    $_ -like "*Email*" -or $_ -like "*Mail*" 
                }
                
                if ($possibleSourceColumns -and $possibleEmailColumns) {
                    $sourceCol = $possibleSourceColumns[0]
                    $emailCol = $possibleEmailColumns[0]
                    
                    Write-Output "Using inferred column names: SourceUsername='$sourceCol', Email='$emailCol'"
                    
                    # Create a new array with properly named properties
                    $newUserMap = @()
                    foreach ($row in $userMap) {
                        $newUserMap += [PSCustomObject]@{
                            SourceUsername = $row.$sourceCol
                            Email = $row.$emailCol
                        }
                    }
                    return $newUserMap
                } else {
                    Write-Error "Cannot determine SourceUsername and Email columns in the CSV. Please rename columns to 'SourceUsername' and 'Email'."
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

function Build-EmailToUsernameMap([string]$Org, [array]$UserMapping) {
    $emailToUsernameMap = @{}
    
    Write-Output "Building email-to-username mapping for target organization '${Org}'..."
    
    # Cache for target org usernames found by email
    $emailCache = @{}
    
    foreach ($mappingEntry in $UserMapping) {
        if (-not [string]::IsNullOrWhiteSpace($mappingEntry.Email)) {
            $targetUsername = Find-UserByEmail -Org $Org -Email $mappingEntry.Email
            if ($targetUsername) {
                Write-Output "Mapped email '$($mappingEntry.Email)' to user '$targetUsername' in target organization."
                $emailToUsernameMap[$mappingEntry.Email] = $targetUsername
                $emailCache[$mappingEntry.SourceUsername] = $mappingEntry.Email
            } else {
                Write-Warning "Could not find user with email '$($mappingEntry.Email)' in target organization."
            }
        } else {
            Write-Warning "Skipping mapping entry for source user '$($mappingEntry.SourceUsername)' due to missing email."
        }
    }
    
    Write-Output "Built mapping for $($emailToUsernameMap.Count) users based on email."
    return @{
        EmailMap = $emailToUsernameMap
        SourceUserToEmailMap = $emailCache
    }
}

# Main execution starts here
Write-Output "Starting GitHub Teams migration from '${SourceOrg}' to '${TargetOrg}'"

# Check if the user mapping file exists
if (-not (Test-Path $UserMappingCsv)) {
    Write-Error "User mapping file not found: ${UserMappingCsv}"
    exit 1
}

# 1. Authenticate for source organization operations
Write-Output "Authenticating with source organization..."
GhAuth "SOURCE_PAT"

# 2. Get all teams from the source organization
Write-Output "Fetching teams from source organization '${SourceOrg}'..."
$sourceTeams = Get-Teams -Org $SourceOrg
Write-Output "Found $($sourceTeams.Count) teams in source organization."

# Display source teams for debugging
Write-Output "Source Teams:"
$sourceTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

# 3. Create teams in the target organization (respecting parent-child relationships)
Write-Output "Authenticating with target organization..."
GhAuth "TARGET_PAT"

# First, check current teams in target org
Write-Output "Checking existing teams in target organization..."
$existingTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Found $($existingTargetTeams.Count) existing teams in target organization."

# Display existing target teams for debugging
Write-Output "Existing Target Teams:"
$existingTargetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

# Store created/matched teams for later use
$processedTeams = @{}

# First, create all parent teams (teams without parent)
Write-Output "Creating parent teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { -not $_.parent }) {
    # Skip teams with empty names
    if ([string]::IsNullOrWhiteSpace($team.name)) {
        Write-Warning "Skipping team with empty name."
        continue
    }
    
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

# Wait a moment to ensure all parent teams are created before proceeding
Write-Output "Waiting for API propagation..."
Start-Sleep -Seconds 5

# Refresh the list of target teams
$targetTeams = Get-Teams -Org $TargetOrg
Write-Output "After creating parent teams: $($targetTeams.Count) teams in target organization."

# Display updated target teams for debugging
Write-Output "Updated Target Teams:"
$targetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

# Then create child teams
Write-Output "Creating child teams in target organization..."
foreach ($team in $sourceTeams | Where-Object { $_.parent }) {
    # Skip teams with empty names
    if ([string]::IsNullOrWhiteSpace($team.name)) {
        Write-Warning "Skipping child team with empty name."
        continue
    }
    
    Write-Output "Processing child team: $($team.name)"
    $existingTeam = $targetTeams | Where-Object { $_.name -eq $team.name }
    
    if ($existingTeam) {
        Write-Output "Team '$($team.name)' already exists in target organization with slug '$($existingTeam.slug)'."
        $processedTeams[$team.name] = $existingTeam
    } else {
        # Find the parent team in the target org
        $parentTeamName = $team.parent.name
        
        # Skip if parent team name is empty
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

# Refresh the list of target teams again
Write-Output "Waiting for API propagation..."
Start-Sleep -Seconds 5  # Allow time for API changes to propagate
$finalTargetTeams = Get-Teams -Org $TargetOrg
Write-Output "Final count after creating all teams: $($finalTargetTeams.Count) teams in target organization."

Write-Output "Teams in target organization:"
$finalTargetTeams | ForEach-Object { Write-Output "- $($_.name) (slug: $($_.slug))" }

# 4. For each team, assign repository permissions
Write-Output "Setting repository permissions for teams..."
$targetRepos = Get-Repos -Org $TargetOrg
$sourceRepos = Get-Repos -Org $SourceOrg # Get source repos for visibility information

# Create a hashtable to track repositories that need to be created
$reposToCreate = @{}

# First pass: identify repositories that need to be created
Write-Output "Analyzing repositories that need to be migrated..."
foreach ($sourceTeam in $sourceTeams) {
    # Skip teams with empty names
    if ([string]::IsNullOrWhiteSpace($sourceTeam.name) -or [string]::IsNullOrWhiteSpace($sourceTeam.slug)) {
        Write-Warning "Skipping team with empty name or slug when analyzing repositories."
        continue
    }
    
    $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeam.slug
    
    foreach ($repo in $teamRepos) {
        # Skip repositories with empty names
        if ([string]::IsNullOrWhiteSpace($repo.name)) {
            Write-Warning "Skipping repository with empty name for team '$($sourceTeam.name)'."
            continue
        }
        
        # Check if the repository exists in the target organization
        $targetRepo = $targetRepos | Where-Object { $_.name -eq $repo.name }
        
        if (-not $targetRepo) {
            # If repository doesn't exist in target org, mark it for creation
            $sourceRepo = $sourceRepos | Where-Object { $_.name -eq $repo.name }
            $isPrivate = $true # Default to private
            if ($sourceRepo) {
                $isPrivate = $sourceRepo.private
            }
            
            if (-not $reposToCreate.ContainsKey($repo.name)) {
                $reposToCreate[$repo.name] = @{
                    Name = $repo.name
                    IsPrivate = $isPrivate
                }
                Write-Output "Repository '$($repo.name)' will need to be created in target organization."
            }
        }
    }
}

# Ask user if they want to create missing repositories
if ($reposToCreate.Count -gt 0) {
    Write-Output "Found $($reposToCreate.Count) repositories that don't exist in the target organization."
    
    if (-not $DryRun) {
        $createRepos = Read-Host "Do you want to create these repositories in the target organization? (Y/N)"
        if ($createRepos -eq "Y" -or $createRepos -eq "y") {
            Write-Output "Creating missing repositories in target organization..."
            foreach ($repoInfo in $reposToCreate.Values) {
                $newRepo = Create-Repository -Org $TargetOrg -RepoName $repoInfo.Name -IsPrivate $repoInfo.IsPrivate
                if ($newRepo) {
                    # Add newly created repository to the list of target repos
                    $targetRepos += $newRepo
                }
            }
        } else {
            Write-Output "Skipping repository creation. Permissions will not be set for non-existent repositories."
        }
    } else {
        Write-Output "Dry-run: Would prompt to create $($reposToCreate.Count) repositories."
    }
}

# Second pass: set repository permissions
foreach ($sourceTeam in $sourceTeams) {
    # Skip teams with empty names
    if ([string]::IsNullOrWhiteSpace($sourceTeam.name) -or [string]::IsNullOrWhiteSpace($sourceTeam.slug)) {
        Write-Warning "Skipping team with empty name or slug when setting permissions."
        continue
    }
    
    $targetTeam = $finalTargetTeams | Where-Object { $_.name -eq $sourceTeam.name }
    
    if ($targetTeam) {
        Write-Output "Setting permissions for team: $($targetTeam.name) (slug: $($targetTeam.slug))"
        $teamRepos = Get-TeamRepos -Org $SourceOrg -TeamSlug $sourceTeam.slug
        
        foreach ($repo in $teamRepos) {
            # Skip repositories with empty names
            if ([string]::IsNullOrWhiteSpace($repo.name)) {
                Write-Warning "Skipping repository with empty name for team '$($targetTeam.name)'."
                continue
            }
            
            # Check if the repository exists in the target organization
            $targetRepo = $targetRepos | Where-Object { $_.name -eq $repo.name }
            
            if ($targetRepo) {
                # Get the exact permission level
                $permission = if ($repo.permissions) {
                    if ($repo.permissions.admin) { "admin" }
                    elseif ($repo.permissions.maintain) { "maintain" }
                    elseif ($repo.permissions.push) { "push" } # write
                    elseif ($repo.permissions.triage) { "triage" }
                    else { "pull" } # read
                } elseif ($repo.role_name) {
                    $repo.role_name
                } else {
                    # If we can't determine permission from the API response, get it directly
                    Get-TeamRepoPermission -Org $SourceOrg -TeamSlug $sourceTeam.slug -RepoName $repo.name
                }
                
                # If still couldn't determine permission, default to read access
                if (-not $permission) {
                    $permission = "pull"
                    Write-Warning "Could not determine permission for team '$($sourceTeam.name)' on repository '$($repo.name)'. Defaulting to 'pull' (read) access."
                }
                
                Write-Output "Setting permission '${permission}' for team '$($targetTeam.name)' on repository '$($targetRepo.name)'."
                Set-TeamRepo
