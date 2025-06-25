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

## Required Secrets & Permissions

### 1. Personal Access Tokens (PATs)

You need two PATs:
- `SOURCE_PAT` — for the source organization
- `TARGET_PAT` — for the target organization

**Required scopes for each PAT:**
- `repo` — Full control of private repositories (includes all sub-scopes)
- `read:org` — Read all organization membership, team, and repository information
- `admin:org` — (optional, but recommended for full team management, especially if you need to create or manage teams)

  #### Fine-grained PAT permissions:
When creating a fine-grained PAT, set the following:
- **Repository permissions:**
  - Metadata: **Read**
  - Actions: **Read and write**
  - Administration: **Read and write**
- **Organization permissions:**
  - Members: **Read and write**

**How to Create a PAT:**
1. Go to [GitHub Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens)
2. Click **Generate new token** (classic)
3. Select the required scopes listed above
4. Save the token and add it to your repository/organization secrets as `SOURCE_PAT` or `TARGET_PAT`

**NOTE:** PATs should only be used with accounts that have admin or owner access to the respective organizations.

---

### 2. GitHub App

The GitHub App is used for team membership and repo permissions assignment in the target org.

## GitHub App Permissions Required

When creating and installing your GitHub App for use with this migration workflow, you must grant it the following permissions:

- **Read access**
  - Metadata

- **Read and write access**
  - Actions
  - Actions variables
  - Administration
  - Codespaces secrets
  - Dependabot secrets
  - Environments
  - Members
  - Organization actions variables
  - Organization administration
  - Organization codespaces secrets
  - Organization dependabot secrets
  - Organization secrets
  - Organization self-hosted runners
  - Secrets

**How to set these permissions:**
1. Go to [GitHub Settings → Developer settings → GitHub Apps](https://github.com/settings/apps)
2. Click your app or create a new one.
3. Under **Permissions & events**, assign the above permissions to your app.
4. Complete the app creation and installation steps as described above.

**Note:**  
These permissions ensure the app can manage teams, members, repository permissions, secrets, and workflows required by the migration process.

**How to Create a GitHub App:**
1. Go to [GitHub Settings → Developer settings → GitHub Apps](https://github.com/settings/apps)
2. Click **New GitHub App**
3. Set the required permissions as above
4. Allow the app to be installed on any organization, or restrict as needed
5. Generate and download the **private key**
6. Save the **App ID** and **private key**; add them as secrets (`GH_APP_ID`, `GH_APP_PRIVATE_KEY`)
7. Install the app in your **target organization** and grant it access to **all repositories** (recommended) or only those you want to manage

**References:**
- [Creating a personal access token](https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token)
- [Creating a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/selecting-permissions-for-a-github-app)

---

## Secrets Used

| Secret Name             | Used For                                  | Where to Use                              |
|-------------------------|-------------------------------------------|-------------------------------------------|
| `SOURCE_PAT`            | PAT for source org (team/repo/member read) | GitHub Actions Secret                     |
| `TARGET_PAT`            | PAT for target org (team/repo management) | GitHub Actions Secret                     |
| `GH_APP_ID`             | GitHub App ID (for team/permission mgmt)  | GitHub Actions Secret                     |
| `GH_APP_PRIVATE_KEY`    | GitHub App private key (for auth)         | GitHub Actions Secret                     |

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
