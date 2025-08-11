#!/usr/bin/env bash
set -euo pipefail

# Worker script for lazy-clone
# Handles individual repository cloning with skip-existing logic

# Arguments:
# $1 - destination directory
# $2 - repository name (owner/name)
# $3 - SSH URL
# $4 - default branch

DESTINATION="$1"
REPO_NAME="$2"
SSH_URL="$3"
DEFAULT_BRANCH="$4"

# Extract repo name without owner
REPO_BASENAME=$(basename "$REPO_NAME")
TARGET_DIR="$DESTINATION/$REPO_BASENAME"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_cloned() {
    echo -e "${GREEN}[cloned]${NC} $1 → $2"
}

log_skip() {
    echo -e "${YELLOW}[skip-existing]${NC} $1 at $2"
}

log_repo_error() {
    echo -e "${RED}[error]${NC} $1 : $2"
}

# Check if repository already exists
if [[ -d "$TARGET_DIR" ]]; then
    log_skip "$REPO_NAME" "$TARGET_DIR"
    exit 0
fi

# Check if it's a git repository (in case of partial clones)
if [[ -d "$TARGET_DIR/.git" ]]; then
    log_skip "$REPO_NAME" "$TARGET_DIR"
    exit 0
fi

# Clone the repository
if git clone --recursive --origin origin --progress "$SSH_URL" "$TARGET_DIR" 2>&1; then
    log_cloned "$REPO_NAME" "$TARGET_DIR"
else
    log_repo_error "$REPO_NAME" "Failed to clone repository"
    exit 1
fi
