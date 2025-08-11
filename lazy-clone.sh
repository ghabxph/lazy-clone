#!/usr/bin/env bash
set -euo pipefail

# lazy-clone — clone all repos from a GitHub user or org (skip-existing; token-aware picker)
# 
# Interactive flow:
# 1. Authenticate (GitHub CLI preferred, GH_TOKEN fallback)
# 2. Pick namespace (user or org from token access)
# 3. Enter absolute destination path
# 4. Clone only missing repositories

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.0.0"

# Default configuration
DEFAULT_CONCURRENCY=6
DEFAULT_INCLUDE_ARCHIVED=true
DEFAULT_INCLUDE_FORKS=true

# Global state
AUTH_METHOD=""
GH_TOKEN=""
NAMESPACE_TYPE=""
NAMESPACE_NAME=""
DESTINATION=""
INCLUDE_ARCHIVED="$DEFAULT_INCLUDE_ARCHIVED"
INCLUDE_FORKS="$DEFAULT_INCLUDE_FORKS"
CONCURRENCY="$DEFAULT_CONCURRENCY"
JSON_OUT=""

# Statistics
TOTAL_ENUMERATED=0
CLONED=0
SKIPPED_EXISTING=0
ERRORS=0
ERROR_LIST=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_cloned() {
    echo -e "${GREEN}[cloned]${NC} $1 → $2"
}

log_skip() {
    echo -e "${YELLOW}[skip-existing]${NC} $1 at $2"
}

log_repo_error() {
    echo -e "${RED}[error]${NC} $1 : $2"
}

# Check if GitHub CLI is available and authenticated
check_gh_auth() {
    if ! command -v gh &> /dev/null; then
        return 1
    fi
    
    if gh auth status &> /dev/null; then
        return 0
    fi
    
    return 1
}

# Authenticate using GitHub CLI
auth_with_gh() {
    log_info "GitHub CLI detected. Attempting to authenticate..."
    
    if ! gh auth status &> /dev/null; then
        log_info "GitHub CLI not authenticated. Starting browser login..."
        echo ""
        echo "A browser window will open for GitHub authentication."
        echo "Please complete the login process in your browser."
        echo ""
        
        if gh auth login -h github.com -p https -w; then
            log_success "GitHub CLI authentication completed"
        else
            log_error "GitHub CLI authentication failed"
            return 1
        fi
    else
        log_info "GitHub CLI already authenticated"
    fi
    
    AUTH_METHOD="gh"
    log_success "Authenticated with GitHub CLI"
    return 0
}

# Authenticate using GH_TOKEN
auth_with_token() {
    log_info "Using GitHub token for authentication..."
    
    if [[ -z "${GH_TOKEN:-}" ]]; then
        echo ""
        echo "Please provide your GitHub token:"
        echo "- Go to: https://github.com/settings/tokens"
        echo "- Click 'Generate new token (classic)'"
        echo "- Select scopes: 'repo' and 'read:org'"
        echo "- Copy the generated token"
        echo ""
        echo -n "Enter your GitHub token (input will be hidden): "
        read -s GH_TOKEN
        echo ""
    fi
    
    if [[ -z "$GH_TOKEN" ]]; then
        log_error "No token provided"
        return 1
    fi
    
    log_info "Validating token..."
    
    # Validate token by calling /user endpoint
    local user_info
    user_info=$(curl -s -H "Authorization: token $GH_TOKEN" \
                     -H "Accept: application/vnd.github.v3+json" \
                     "https://api.github.com/user" 2>/dev/null || echo "")
    
    if [[ -z "$user_info" ]] || echo "$user_info" | grep -q '"message":"Bad credentials"'; then
        log_error "Invalid GitHub token"
        return 1
    fi
    
    local username
    username=$(echo "$user_info" | jq -r .login)
    log_success "Authenticated with GitHub token as: $username"
    
    AUTH_METHOD="token"
    return 0
}

# Get current user login
get_user_login() {
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        gh api user -q .login
    else
        curl -s -H "Authorization: token $GH_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com/user" | jq -r .login
    fi
}

# Get organizations available to the token
get_organizations() {
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        gh api user/orgs -q '.[].login'
    else
        local page=1
        local orgs=""
        while true; do
            local response
            response=$(curl -s -H "Authorization: token $GH_TOKEN" \
                           -H "Accept: application/vnd.github.v3+json" \
                           "https://api.github.com/user/orgs?per_page=100&page=$page")
            
            local page_orgs
            page_orgs=$(echo "$response" | jq -r '.[].login' | grep -v '^null$')
            
            if [[ -z "$page_orgs" ]]; then
                break
            fi
            
            orgs="$orgs"$'\n'"$page_orgs"
            page=$((page + 1))
        done
        
        echo "$orgs" | sort -u
    fi
}

# Present namespace picker
present_namespace_picker() {
    local user_login
    user_login=$(get_user_login)
    
    if [[ -z "$user_login" ]]; then
        log_error "Failed to get user login"
        exit 1
    fi
    
    log_info "Available namespaces:"
    echo "1) User: $user_login"
    
    local orgs
    orgs=$(get_organizations)
    local org_count=2
    
    if [[ -n "$orgs" ]]; then
        while IFS= read -r org; do
            if [[ -n "$org" ]]; then
                echo "$org_count) Org: $org"
                org_count=$((org_count + 1))
            fi
        done <<< "$orgs"
    fi
    
    echo ""
    read -p "Select namespace (1-$((org_count-1))): " selection
    
    if [[ "$selection" == "1" ]]; then
        NAMESPACE_TYPE="user"
        NAMESPACE_NAME="$user_login"
    else
        local org_index=1
        while IFS= read -r org; do
            if [[ -n "$org" ]]; then
                if [[ $((selection - 1)) == $org_index ]]; then
                    NAMESPACE_TYPE="org"
                    NAMESPACE_NAME="$org"
                    break
                fi
                org_index=$((org_index + 1))
            fi
        done <<< "$orgs"
    fi
    
    if [[ -z "$NAMESPACE_NAME" ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    log_success "Selected: $NAMESPACE_TYPE/$NAMESPACE_NAME"
}

# Get destination path
get_destination() {
    while true; do
        echo -n "Enter absolute destination directory (e.g., /srv/git/$NAMESPACE_NAME): "
        read -r dest
        
        if [[ "$dest" = /* ]]; then
            DESTINATION="$dest"
            mkdir -p "$DESTINATION"
            log_success "Destination: $DESTINATION"
            break
        else
            log_error "Please enter an absolute path (starting with /)"
        fi
    done
}

# Enumerate repositories
enumerate_repos() {
    log_info "Enumerating repositories for $NAMESPACE_TYPE/$NAMESPACE_NAME..." >&2
    
    if [[ "$AUTH_METHOD" == "gh" ]]; then
        local gh_output
        gh_output=$(gh repo list "$NAMESPACE_NAME" --limit 1000 --json name,sshUrl,isFork,isArchived,owner,defaultBranchRef)
        
        # Validate GitHub CLI output
        if ! echo "$gh_output" | jq empty 2>/dev/null; then
            log_error "Invalid JSON output from GitHub CLI" >&2
            return 1
        fi
        
        # Check if output is empty array
        local repo_count
        repo_count=$(echo "$gh_output" | jq length)
        
        if [[ "$repo_count" -eq 0 ]]; then
            log_warning "No repositories found for $NAMESPACE_TYPE/$NAMESPACE_NAME" >&2
            echo "[]"
            return 0
        fi
        
        echo "$gh_output"
    else
        # Fallback to REST API
        local page=1
        local all_repos="[]"
        
        while true; do
            local endpoint
            if [[ "$NAMESPACE_TYPE" == "user" ]]; then
                endpoint="https://api.github.com/users/$NAMESPACE_NAME/repos?type=all&per_page=100&page=$page"
            else
                endpoint="https://api.github.com/orgs/$NAMESPACE_NAME/repos?type=all&per_page=100&page=$page"
            fi
            
            local response
            response=$(curl -s -H "Authorization: token $GH_TOKEN" \
                           -H "Accept: application/vnd.github.v3+json" \
                           "$endpoint")
            
            # Check if response is valid JSON and has content
            if ! echo "$response" | jq empty 2>/dev/null; then
                log_error "Invalid JSON response from GitHub API"
                return 1
            fi
            
            local repos_count
            repos_count=$(echo "$response" | jq length)
            
            if [[ "$repos_count" -eq 0 ]]; then
                break
            fi
            
            # Transform the response to match GitHub CLI format
            local transformed_repos
            transformed_repos=$(echo "$response" | jq '[.[] | {
                name: .name,
                sshUrl: .ssh_url,
                isFork: .fork,
                isArchived: .archived,
                owner: .owner.login,
                defaultBranchRef: {name: .default_branch}
            }]')
            
            # Merge with existing repos
            all_repos=$(echo "$all_repos" | jq --argjson new "$transformed_repos" '. + $new')
            page=$((page + 1))
        done
        
        echo "$all_repos"
    fi
}

# Filter repositories based on settings
filter_repos() {
    local repos="$1"
    
    # Validate input JSON
    if ! echo "$repos" | jq empty 2>/dev/null; then
        log_error "Invalid JSON input to filter_repos"
        return 1
    fi
    
    echo "$repos" | jq -r '.[] | {
        name: .name,
        sshUrl: .sshUrl,
        owner: .owner.login,
        defaultBranchRef: .defaultBranchRef.name
    }'
}

# Process repositories
process_repos() {
    local repos="$1"
    local temp_file
    temp_file=$(mktemp)
    
    # Write repos to temp file for xargs (already in the correct format)
    echo "$repos" > "$temp_file"
    

    
    TOTAL_ENUMERATED=$(echo "$repos" | wc -l)
    
    log_info "Found $TOTAL_ENUMERATED repositories"
    log_info "Starting clone process with concurrency $CONCURRENCY..."
    
    # Process repos with xargs
    xargs -P "$CONCURRENCY" -n1 bash -c '
        IFS="|" read -r repo_name ssh_url default_branch <<< "$1"
        bash "'"$SCRIPT_DIR"'/scripts/process_repo.sh" \
            "'"$DESTINATION"'" \
            "$repo_name" \
            "$ssh_url" \
            "$default_branch"
    ' bash < "$temp_file"
    
    rm -f "$temp_file"
}

# Generate JSON summary
generate_summary() {
    local summary
    summary=$(cat <<EOF
{
  "run": {
    "auth_method": "$AUTH_METHOD",
    "namespace_type": "$NAMESPACE_TYPE",
    "namespace_name": "$NAMESPACE_NAME",
    "destination": "$DESTINATION",
    "include_archived": $INCLUDE_ARCHIVED,
    "include_forks": $INCLUDE_FORKS,
    "concurrency": $CONCURRENCY
  },
  "stats": {
    "total_enumerated": $TOTAL_ENUMERATED,
    "cloned": $CLONED,
    "skipped_existing": $SKIPPED_EXISTING,
    "errors": $ERRORS
  },
  "errors": [
EOF
    )
    
    if [[ ${#ERROR_LIST[@]} -gt 0 ]]; then
        for error in "${ERROR_LIST[@]}"; do
            summary="$summary"$'\n    '"$error,"
        done
        summary="${summary%,}"  # Remove trailing comma
    fi
    
    summary="$summary"$'\n  ]'$'\n}'
    
    echo "$summary"
    
    if [[ -n "$JSON_OUT" ]]; then
        echo "$summary" > "$JSON_OUT"
        log_info "JSON summary written to: $JSON_OUT"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auth)
                AUTH_METHOD="$2"
                shift 2
                ;;
            --type)
                NAMESPACE_TYPE="$2"
                shift 2
                ;;
            --name)
                NAMESPACE_NAME="$2"
                shift 2
                ;;
            --dest)
                DESTINATION="$2"
                shift 2
                ;;
            --include-archived)
                INCLUDE_ARCHIVED="$2"
                shift 2
                ;;
            --include-forks)
                INCLUDE_FORKS="$2"
                shift 2
                ;;
            --concurrency)
                CONCURRENCY="$2"
                shift 2
                ;;
            --json-out)
                JSON_OUT="$2"
                shift 2
                ;;
            --help|-h)
                cat <<EOF
lazy-clone — clone all repos from a GitHub user or org (skip-existing; token-aware picker)

Usage: $0 [OPTIONS]

Options:
  --auth <auto|gh|token>     Authentication method (default: auto)
  --type <user|org>          Namespace type
  --name <namespace>         Namespace name
  --dest <path>              Absolute destination path
  --include-archived <bool>  Include archived repos (default: true)
  --include-forks <bool>     Include forked repos (default: true)
  --concurrency <int>        Number of concurrent clones (default: 6)
  --json-out <path>          Write JSON summary to file
  --help, -h                 Show this help message

Interactive mode:
  $0
  # Will prompt for authentication choice, then namespace selection and destination

Examples:
  # Interactive mode
  $0

  # Non-interactive mode
  $0 --auth gh --type user --name myuser --dest /srv/git/myuser

  # Clone org repos with custom settings
  $0 --auth token --type org --name myorg --dest /srv/git/myorg \\
     --include-archived false --include-forks false --concurrency 8
EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    echo "lazy-clone v$VERSION"
    echo "=================="
    echo ""
    
    parse_args "$@"
    
    # Authentication
    if [[ -z "$AUTH_METHOD" ]]; then
        if check_gh_auth; then
            echo ""
            echo "Authentication Options:"
            echo "1) GitHub CLI (recommended - opens browser)"
            echo "2) GitHub Token (paste your token)"
            echo ""
            read -p "Choose authentication method (1 or 2): " auth_choice
            
            case "$auth_choice" in
                1)
                    auth_with_gh || exit 1
                    ;;
                2)
                    auth_with_token || exit 1
                    ;;
                *)
                    log_error "Invalid choice. Please select 1 or 2."
                    exit 1
                    ;;
            esac
        else
            log_info "GitHub CLI not available, using token authentication"
            auth_with_token || exit 1
        fi
    elif [[ "$AUTH_METHOD" == "gh" ]]; then
        auth_with_gh || exit 1
    elif [[ "$AUTH_METHOD" == "token" ]]; then
        auth_with_token || exit 1
    else
        log_error "Invalid auth method: $AUTH_METHOD"
        exit 1
    fi
    
    # Namespace selection
    if [[ -z "$NAMESPACE_TYPE" ]] || [[ -z "$NAMESPACE_NAME" ]]; then
        present_namespace_picker
    fi
    
    # Destination
    if [[ -z "$DESTINATION" ]]; then
        get_destination
    elif [[ ! "$DESTINATION" = /* ]]; then
        log_error "Destination must be an absolute path: $DESTINATION"
        exit 1
    else
        mkdir -p "$DESTINATION"
    fi
    
    # Enumerate and process repositories
    local repos
    log_info "Starting repository enumeration..."
    repos=$(enumerate_repos)
    local enum_status=$?
    
    log_info "Enumeration completed with status: $enum_status"
    
    if [[ $enum_status -ne 0 ]]; then
        log_error "Failed to enumerate repositories"
        exit 1
    fi
    
    if [[ -z "$repos" ]]; then
        log_warning "No repositories found"
        generate_summary
        exit 0
    fi
    
    local filtered_repos
    log_info "Starting repository filtering..."
    # Filter repositories inline instead of using function
    filtered_repos=$(echo "$repos" | jq -r '.[] | "\(.owner.login)/\(.name)|\(.sshUrl)|\(.defaultBranchRef.name)"')
    local filter_status=$?
    
    log_info "Filtering completed with status: $filter_status"
    
    if [[ $filter_status -ne 0 ]]; then
        log_error "Failed to filter repositories"
        exit 1
    fi
    
    if [[ -z "$filtered_repos" ]]; then
        log_warning "No repositories match the current filters"
        generate_summary
        exit 0
    fi
    
    process_repos "$filtered_repos"
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to process repositories"
        exit 1
    fi
    
    echo ""
    log_success "Operation completed!"
    echo "Summary: $CLONED cloned, $SKIPPED_EXISTING skipped, $ERRORS errors"
    
    generate_summary
}

# Export variables for worker script
export SCRIPT_DIR
export DESTINATION
export CLONED
export SKIPPED_EXISTING
export ERRORS
export ERROR_LIST

# Run main function
main "$@"
