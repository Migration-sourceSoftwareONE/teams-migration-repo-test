name: "Migrate GitHub Teams"

on:
  workflow_dispatch:
    inputs:
      source_org:
        description: 'Source organization name'
        required: true
      target_org:
        description: 'Target organization name'
        required: true
      dry_run:
        description: 'Enable dry-run mode (true/false)'
        required: false
        default: 'false'

jobs:
  migrate-teams:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v3

      - name: Install GitHub CLI
        run: |
          sudo apt-get update
          sudo apt-get install -y gh

      - name: Install PowerShell
        run: |
          sudo apt-get install -y powershell

      - name: Run Team Migration Script
        env:
          SOURCE_PAT: ${{ secrets.SOURCE_PAT }}
          TARGET_PAT: ${{ secrets.TARGET_PAT }}
        run: |
          pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File migration/Migrate-GitHubTeams.ps1 `
            -SourceOrg "${{ github.event.inputs.source_org }}" `
            -TargetOrg "${{ github.event.inputs.target_org }}" `
            -UserMappingCsv "user-map.csv" `
            $([ "${{ github.event.inputs.dry_run }}" == 'true' ] && echo "-DryRun")
