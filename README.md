# GitHub Teams Migration Workflow

## Overview

This workflow and accompanying PowerShell script automate the migration of GitHub teams—including their structure, memberships, and repository permissions—from a **source organization** to a **target organization**. The migration is designed to be robust, auditable, and repeatable, supporting both dry-run (test) and live migration modes.

Key features include:
- **Team structure migration** (including parent/child relationships and privacy/description)
- **Repository permission replication** for each team
- **Team member migration** via user email mapping for accurate cross-org member assignment
- **Unmapped user reporting** for audit and manual review

---

## How It Works

1. **Authentication:**
   - The workflow supports both **classic Personal Access Tokens (PATs)** and a **GitHub App** for various stages of the migration.
   - PATs are used for initial team and repo creation.
   - The GitHub App is used for assigning permissions and memberships, leveraging organizational access and auditability.

2. **Team Migration:**
   - All teams in the source org are discovered, including their parent-child hierarchy.
   - Teams are created in the target org, preserving structure, privacy, and descriptions.

3. **Repository Permissions:**
   - For each team, all repository permissions in the source org are retrieved.
   - Equivalent permissions are set for the corresponding teams in the target org (if the repository exists).

4. **Team Memberships:**
   - Memberships are migrated using a **user mapping CSV file** (see below).
   - Each source username is mapped to a target user via email.
   - Only users present in the target org are added; unmapped users are logged for review.

5. **Reporting:**
   - Any team members that could not be mapped to the target org are written to `unmapped_team_members.csv` and uploaded as an artifact for manual follow-up.

---

## Secrets Used

| Secret Name             | Used For                                  |
|-------------------------|-------------------------------------------|
| `SOURCE_PAT`            | PAT for reading teams/repos/members in the source org (needs `read:org`, `repo`, and team management permissions) |
| `TARGET_PAT`            | PAT for creating teams/repos in the target org (same scopes as above) |
| `GH_APP_ID`             | GitHub App ID (for organization-level repo/team/member management) |
| `GH_APP_PRIVATE_KEY`    | GitHub App private key (for generating installation tokens) |

**Note:**  
- The GitHub App must be installed in the target organization with at least:  
  - `Contents: Read & Write`, `Organization administration: Read & Write`, and `Members: Read` permissions.
- PATs should have minimal required permissions and be stored securely as organization or repository secrets.

---

## User Mapping CSV

The script **requires a CSV file** that maps source org usernames to their email addresses, which are then used to find and match users in the target org.

**CSV Format:**

| SourceUsername | UserEmail              |
|----------------|-----------------------|
| alice          | alice@target.com      |
| bob            | bob@target.com        |
| ...            | ...                   |

- `SourceUsername`: GitHub username in the source org.
- `UserEmail`: Email address that matches a user in the target org.

**Why is this needed?**  
GitHub usernames may differ between organizations or users may have changed accounts. Mapping by email ensures correct user identification and assignment.

---

## How to Run the Migration

### 1. Prepare the User Mapping CSV

- Create a CSV file (e.g., `user-map.csv`) as described above.
- Ensure it is committed to the repository or uploaded as an artifact accessible in the workflow.

### 2. Configure Secrets

- Add `SOURCE_PAT`, `TARGET_PAT`, `GH_APP_ID`, and `GH_APP_PRIVATE_KEY` as repository or organization secrets.
- Ensure your GitHub App is installed in the target org and has the necessary permissions.

### 3. Trigger the Workflow

You can run the migration manually using the GitHub Actions "workflow_dispatch" event.  
Go to the "Actions" tab, select "Migrate GitHub Teams", and click "Run workflow".

**Workflow Input Parameters:**

- **source_org**: The GitHub organization you are migrating from.
- **target_org**: The GitHub organization you are migrating to.
- **user_mapping_csv**: Path to the user mapping CSV file (relative to repository root).
- **dry_run** (optional): `true` or `false`. Set to `true` to perform a dry-run (no changes will be made).

### 4. Monitor the Workflow

- Review the Actions logs for progress and troubleshooting.
- At the end of execution, download `unmapped_team_members.csv` from the workflow artifacts to review any unmapped users.

---

## Example: Running a Migration

1. **Prepare your `user-map.csv` file** and commit it to your repo.
2. **Navigate to the workflow's Run interface** in GitHub Actions.
3. **Fill in the parameters:**
   - `source_org`: `my-old-org`
   - `target_org`: `my-new-org`
   - `user_mapping_csv`: `user-map.csv`
   - `dry_run`: `true` (for a test run)

4. **Start the workflow** and monitor logs and artifacts.

---

## Notes & Limitations

- Team migration assumes that team and repo names are consistent across orgs; repos missing in the target org will be skipped for permission assignment.
- Only users present in the target org and matched by email will be added to teams.
- Manual review of the unmapped users report is recommended post-migration.

---

## Troubleshooting

- **Authentication errors:** Ensure all secrets are correctly set and that tokens/apps have the required permissions.
- **Unmapped users:** Update the user mapping CSV as needed and rerun the migration (only unmapped users will be affected).
- **Repository or team not found in target org:** Ensure all required repos/teams exist or are created during migration.

---

## Further Reading

- [GitHub REST API Docs: Teams](https://docs.github.com/en/rest/teams/teams)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [GitHub Apps Permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/selecting-permissions-for-a-github-app)

---

**Questions?**  
Open an issue or contact your GitHub administrator for support!
