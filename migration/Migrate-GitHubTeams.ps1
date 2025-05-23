param (
    [Parameter(Mandatory=$true)][string]$SourceOrg,
    [Parameter(Mandatory=$true)][string]$TargetOrg,
    [Parameter(Mandatory=$true)][string]$MappingCsv,
    [switch]$DryRun,
    [string]$SourceToken,
    [string]$TargetToken
)

# Load user mapping
$UserMap = @{}
Import-Csv -Path $MappingCsv | ForEach-Object {
    $UserMap[$_.source_username] = $_.email
}

# Helper: Set token context
function Set-GitHubContext {
    param (
        [string]$Org,
        [string]$Token,
        [string]$Alias
    )
    if ($Token) {
        gh auth logout --hostname github.com --yes
        gh auth login --hostname github.com --with-token <<< $Token
    }

    if (-not (gh auth status 2>$null)) {
        throw "GitHub CLI not authenticated for $Alias org"
    }
}

# Set auth contexts
if ($SourceToken) { Set-GitHubContext -Org $SourceOrg -Token $SourceToken -Alias "Source" }
if ($TargetToken) { Set-GitHubContext -Org $TargetOrg -Token $TargetToken -Alias "Target" }

# Helper: log entries
function Write-Log {
    param ($Message)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$time`t$Message"
    Add-Content -Path "execution-log.txt" -Value $entry
    Write-Host $entry
}

# Collect existing teams in target
$TargetTeams = @{}
gh api "orgs/$TargetOrg/teams?per_page=100" --paginate | ConvertFrom-Json | ForEach-Object {
    $TargetTeams[$_.name.ToLower()] = $_
}

# Get all teams in source org
$SourceTeams = gh api "orgs/$SourceOrg/teams?per_page=100" --paginate | ConvertFrom-Json

# Track skipped data
$SkippedTeams = @()
$SkippedRepos = @()
$UnmappedUsers = @()

# Step 1: Create teams
foreach ($team in $SourceTeams) {
    $teamName = $team.name
    $slug = $team.slug
    $parentSlug = $team.parent?.slug
    $privacy = $team.privacy
    $desc = $team.description

    if ($TargetTeams.ContainsKey($teamName.ToLower())) {
        $SkippedTeams += [PSCustomObject]@{Team=$teamName; Reason="Already exists"}
        continue
    }

    $args = @("orgs/$TargetOrg/teams", "--method", "POST", "--field", "name=$teamName", "--field", "privacy=$privacy")
    if ($desc) { $args += "--field"; $args += "description=$desc" }
    if ($parentSlug) { $args += "--field"; $args += "parent_team_id=$(gh api orgs/$TargetOrg/teams/$parentSlug | jq -r '.id')" }

    Write-Log "Creating team: $teamName"
    if (-not $DryRun) {
        gh api @args
    }
}

# Refresh target teams after creation
$TargetTeams = @{}
gh api "orgs/$TargetOrg/teams?per_page=100" --paginate | ConvertFrom-Json | ForEach-Object {
    $TargetTeams[$_.name.ToLower()] = $_
}

# Step 2: Migrate team members and permissions
foreach ($team in $SourceTeams) {
    $teamName = $team.name
    $slug = $team.slug
    $targetSlug = $TargetTeams[$teamName.ToLower()].slug

    # Migrate members
    $members = gh api "orgs/$SourceOrg/teams/$slug/members?per_page=100" --paginate | ConvertFrom-Json
    foreach ($member in $members) {
        $sourceUsername = $member.login
        $email = $UserMap[$sourceUsername]
        if (-not $email) {
            $UnmappedUsers += [PSCustomObject]@{SourceUser=$sourceUsername; Reason="No email mapping"}
            continue
        }

        $targetUser = gh api "search/users?q=$email+in:email" | ConvertFrom-Json | Select-Object -ExpandProperty items | Where-Object { $_.type -eq "User" }
        if (-not $targetUser) {
            $UnmappedUsers += [PSCustomObject]@{SourceUser=$sourceUsername; Reason="Email not found in target org"}
            continue
        }

        Write-Log "Adding $($targetUser.login) to $teamName"
        if (-not $DryRun) {
            gh api "orgs/$TargetOrg/teams/$targetSlug/memberships/$($targetUser.login)" --method PUT --field role=member | Out-Null
        }
    }

    # Migrate repository permissions
    $repos = gh api "orgs/$SourceOrg/teams/$slug/repos?per_page=100" --paginate | ConvertFrom-Json
    foreach ($repo in $repos) {
        $repoName = $repo.name
        $permission = $repo.permissions | Get-Member -MemberType NoteProperty | Where-Object { $repo.permissions.$($_.Name) -eq $true } | Select-Object -First 1 -ExpandProperty Name

        # Check if repo exists in target
        $exists = gh repo view "$TargetOrg/$repoName" 2>$null
        if (-not $exists) {
            $SkippedRepos += [PSCustomObject]@{Team=$teamName; Repo=$repoName; Reason="Missing in target org"}
            continue
        }

        Write-Log "Assigning $teamName to $repoName with $permission"
        if (-not $DryRun) {
            gh api "orgs/$TargetOrg/teams/$targetSlug/repos/$TargetOrg/$repoName" --method PUT --field permission=$permission | Out-Null
        }
    }
}

# Export skipped logs
$SkippedTeams | Export-Csv -NoTypeInformation -Path "teams-skipped.csv"
$UnmappedUsers | Export-Csv -NoTypeInformation -Path "users-unmapped.csv"
$SkippedRepos | Export-Csv -NoTypeInformation -Path "repos-skipped.csv"

Write-Log "✅ Migration script completed."
