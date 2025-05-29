param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [string]$Scope = "actionsreposecrets",
    [switch]$Force
)

# Read PATs from environment variables
$SourcePAT = $env:SOURCE_PAT
$TargetPAT = $env:TARGET_PAT

if (-not $SourcePAT) {
    Write-Error "Environment variable 'SOURCE_PAT' is not set."
    exit 1
}

if (-not $TargetPAT) {
    Write-Error "Environment variable 'TARGET_PAT' is not set."
    exit 1
}

function Invoke-GitHubApi {
    param($Method, $Uri, $Token, $Body = $null)
    $Headers = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }
    $BodyJson = if ($Body) { $Body | ConvertTo-Json -Depth 10 } else { $null }
    try {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $BodyJson
    } catch {
        # Suppress 404 for existence checks; warn otherwise
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Warning "API call failed: $($_.Exception.Message) [$Method $Uri]"
        }
        return $null
    }
}

# (Remaining functions are unchanged. They use $SourcePAT and $TargetPAT as before.)

foreach ($t in $Scope.Split(',')) {
    switch ($t.Trim().ToLower()) {
        'actionsreposecrets'    { Migrate-ActionsRepoSecrets }
        'actionsrepovariables'  { Migrate-ActionsRepoVariables }
        'dependabotreposecrets' { Migrate-DependabotRepoSecrets }
        'codespacesreposecrets' { Migrate-CodespacesRepoSecrets }
        'actionsenvsecrets'     { Migrate-ActionsEnvSecrets }
        'actionsenvvariables'   { Migrate-ActionsEnvVariables }
        'actionsorgsecrets'     { Migrate-ActionsOrgSecrets }
        'actionsorgvariables'   { Migrate-ActionsOrgVariables }
        'dependabotorgsecrets'  { Migrate-DependabotOrgSecrets }
        'codespacesorgsecrets'  { Migrate-CodespacesOrgSecrets }
        default { Write-Warning "Unknown type: $t" }
    }
}
