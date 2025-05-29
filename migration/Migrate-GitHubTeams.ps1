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
