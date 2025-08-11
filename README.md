# lazy-clone

A robust GitHub repository automation script that provides an authentication-first workflow with token-aware namespace selection and clone-only behavior.

## Features

- **Authentication-first workflow**: Interactive GitHub CLI or token authentication
- **Token-aware namespace picker**: Automatically discovers user and accessible organizations
- **Clone-only behavior**: Only clones missing repositories; never updates existing ones
- **General-purpose design**: No hard-coded usernames or organizations
- **SSH-first**: Uses SSH for all Git operations
- **Parallel processing**: Configurable concurrency for faster operations
- **Comprehensive coverage**: Includes forks, private, internal, and archived repositories
- **Submodule support**: Handles Git submodules and LFS automatically
- **Structured output**: JSON summaries with statistics and error reporting
- **Idempotent**: Safe to rerun multiple times

## Quick Start

```bash
# Make executable and run
chmod +x lazy-clone.sh
./lazy-clone.sh
```

This will:
1. **Choose authentication method**:
   - GitHub CLI (opens browser for login)
   - GitHub Token (paste your token)
2. **Present namespace picker** showing your account and accessible organizations
3. **Ask for destination** (absolute path required)
4. **Clone only missing repositories** (skip existing ones)

## What it does

The script automatically:

1. **Authenticates** with GitHub (CLI preferred, token fallback)
2. **Discovers** your account and accessible organizations
3. **Enumerates** all repositories in selected namespace
4. **Clones** only missing repositories to local directories
5. **Handles** submodules and LFS automatically
6. **Reports** detailed statistics and JSON summaries

## Configuration

### Interactive Configuration

The script automatically discovers available namespaces:
- **User account**: Your personal repositories
- **Organizations**: Any orgs your token can access
- **Destination**: Absolute path you specify (created if missing)

### Command Line Options

```bash
# Non-interactive mode
./lazy-clone.sh --auth gh --type user --name myuser --dest /srv/git/myuser
./lazy-clone.sh --auth token --type org --name myorg --dest /srv/git/myorg

# Custom settings
./lazy-clone.sh --include-archived false --include-forks false --concurrency 8
```

### Environment Variables

- `GH_TOKEN`: GitHub token for authentication (if not using CLI)
- `GIT_SSH_COMMAND`: Custom SSH command (e.g., `"ssh -o StrictHostKeyChecking=accept-new"`)

## Authentication

The script offers a clear choice between two authentication methods:

### 1. GitHub CLI (Recommended)
When you choose this option:
- A browser window automatically opens
- Complete GitHub login in your browser
- No token management required
- Automatic token refresh

**Benefits:**
- Secure browser-based authentication
- No need to copy/paste tokens
- Handles 2FA automatically
- Tokens are managed securely by GitHub CLI

### 2. GitHub Token
When you choose this option:
- Script guides you to GitHub token settings
- Copy your token and paste it securely
- Token is validated immediately

**Token Requirements:**
- `repo` scope for private repositories
- `read:org` scope for organization access
- SSH key configured on GitHub for cloning

**Getting a Token:**
1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Select scopes: `repo` and `read:org`
4. Copy the generated token

## Repository Processing

### New Repositories
- Cloned with `--recursive` for submodules
- Uses SSH URLs: `git@github.com:<owner>/<name>.git`

### Existing Repositories
- **Skipped entirely** - no updates or modifications
- Safe to run multiple times without affecting existing work

### Clone-Only Philosophy
This tool is designed for initial repository setup and incremental addition, not maintenance.

## Output

### Real-time Logging
```
[INFO] [ghabxph] ghabxph/my-repo: cloning...
[SUCCESS] [ghabxph] ghabxph/my-repo: cloned
[INFO] [hawksightco] hawksightco/org-repo: updating...
[SUCCESS] [hawksightco] hawksightco/org-repo: updated
```

### Final Summary
```
=== FINAL SUMMARY ===

Namespace: ghabxph
  Total repositories: 15
  Cloned: 3
  Updated: 12
  Skipped: 0
  Errors: 0

JSON Summary for ghabxph:
{
  "namespace": "ghabxph",
  "total": 15,
  "cloned": 3,
  "updated": 12,
  "skipped": 0,
  "errors": []
}
```

## Error Handling

### SSH Authentication
If SSH authentication fails:
```
[ERROR] SSH authentication failed. Add your SSH public key to GitHub (https://github.com/settings/keys).
[INFO] Public key location: ~/.ssh/id_ed25519.pub
```

### Rate Limiting
- Automatically handles GitHub API rate limits
- Backs off on secondary rate limits (403 errors)

### Repository Errors
- Failed clones are recorded but don't stop processing
- Skip-existing logic prevents duplicate work

## Requirements

### System Dependencies
- `bash` (version 4.0+)
- `git`
- `ssh`
- `curl`
- `jq` (for JSON processing)
- `xargs` (for concurrency)

### Optional Dependencies
- `gh` (GitHub CLI) - installed automatically if missing
- `git-lfs` - for Large File Storage support

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd lazy-clone

# Make executable
chmod +x lazy-clone.sh
chmod +x scripts/process_repo.sh
```

### Dependencies

The script requires these tools to be installed:

```bash
# Ubuntu/Pop!_OS
sudo apt-get install -y git openssh-client curl jq

# GitHub CLI (optional but recommended)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
  sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
  sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null && \
  sudo apt-get update && sudo apt-get install -y gh
```

## Usage Examples

### Interactive Mode
```bash
./lazy-clone.sh
# 1. Choose authentication method (GitHub CLI or Token)
# 2. Select namespace (user or org)
# 3. Enter destination path
```

### Non-Interactive Mode
```bash
# Clone user repositories
./lazy-clone.sh \
  --auth gh \
  --type user \
  --name myusername \
  --dest /srv/git/myusername

# Clone organization repositories
./lazy-clone.sh \
  --auth token \
  --type org \
  --name myorg \
  --dest /srv/git/myorg

# Custom settings
./lazy-clone.sh \
  --include-archived false \
  --include-forks false \
  --concurrency 8
```

### With Custom SSH Configuration
```bash
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" ./lazy-clone.sh
```

## Safety Features

- **Idempotent**: Can be run multiple times safely
- **Non-destructive**: Never deletes or modifies existing repositories
- **Skip-existing**: Automatically skips repositories that already exist
- **Error-isolated**: Individual repository failures don't stop the process
- **SSH-ready**: Provides clear guidance for SSH key setup

## Troubleshooting

### SSH Issues
1. Generate SSH key: `ssh-keygen -t ed25519 -C "your_email@example.com"`
2. Add to SSH agent: `ssh-add ~/.ssh/id_ed25519`
3. Add to GitHub: Copy `~/.ssh/id_ed25519.pub` to https://github.com/settings/keys

### Authentication Issues
1. Try GitHub CLI: `gh auth login`
2. Or use a token with appropriate permissions
3. Verify token with: `curl -H "Authorization: token YOUR_TOKEN" https://api.github.com/user`

### Permission Issues
- Ensure you have access to the repositories
- Check organization membership for org repos
- Verify token has correct scopes



## License

This script is provided as-is for automation purposes. Use responsibly and in accordance with GitHub's terms of service.
