#!/bin/bash
# systivate-update.sh — Rebase Ghostty-Systivate patches onto a new upstream release.
#
# Usage:
#   ./systivate-update.sh v1.3.1          # rebase onto specific tag
#   ./systivate-update.sh                 # rebase onto latest upstream tag
#   ./systivate-update.sh --dry-run       # show what would happen without doing it
#   ./systivate-update.sh v1.3.1 --build  # rebase + build + deploy
#
# The Systivate patches are the commits between the upstream base and HEAD.
# This script rebases them onto the new upstream version, preserving each
# patch as a discrete commit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BRANCH="systivate/custom-tabs-and-scroll"
UPSTREAM_REMOTE="upstream"
FORK_REMOTE="origin"
APP_NAME="Ghostty-Systivate.app"
INSTALL_DIR="/Applications/$APP_NAME"
BUILD_DIR="build_output"
DEV_TEAM="2NH3YEUKTL"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*"; }

# Verify code signing coherence: main binary and all embedded frameworks
# must share the same Team ID, and codesign --deep must pass.
verify_codesign() {
    local app="$1"
    local binary="$app/Contents/MacOS/Ghostty"

    # Deep verify: checks main binary + all embedded frameworks/dylibs
    local verify_output
    if ! verify_output=$(codesign --verify --deep --strict "$app" 2>&1); then
        err "Code signature verification failed for $app"
        echo "$verify_output" | sed 's/^/    /'
        exit 1
    fi

    # Check Team ID consistency across all embedded frameworks
    local main_team
    main_team=$(codesign -dvvv "$binary" 2>&1 | grep TeamIdentifier | cut -d= -f2)
    if [[ -z "$main_team" ]]; then
        err "Could not extract Team ID from $binary"
        exit 1
    fi

    local fw_dir="$app/Contents/Frameworks"
    if [[ -d "$fw_dir" ]]; then
        for fw in "$fw_dir"/*.framework; do
            [[ -e "$fw" ]] || continue
            local fw_name
            fw_name=$(basename "$fw")
            local fw_team
            fw_team=$(codesign -dvvv "$fw" 2>&1 | grep TeamIdentifier | cut -d= -f2)
            if [[ "$fw_team" != "$main_team" ]]; then
                err "Team ID mismatch: $fw_name ($fw_team) != main binary ($main_team)"
                err "This will cause dyld to abort at launch (Library not loaded)"
                exit 1
            fi
        done
    fi

    ok "Code signing coherent (Team: $main_team)"
}

DRY_RUN=0
DO_BUILD=0
AUTO_YES=0
TARGET_TAG=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --build)   DO_BUILD=1 ;;
        --yes|-y)  AUTO_YES=1 ;;
        v*)        TARGET_TAG="$arg" ;;
    esac
done

# Ensure we're on the right branch
current_branch=$(git branch --show-current)
if [[ "$current_branch" != "$BRANCH" ]]; then
    err "Not on $BRANCH (currently on $current_branch)"
    exit 1
fi

# Ensure working tree is clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree is dirty. Commit or stash changes first."
    echo "  Unstaged:"
    git diff --name-only
    echo "  Staged:"
    git diff --cached --name-only
    exit 1
fi

# Fetch upstream (ignore rejected tags — harmless warnings)
info "Fetching upstream..."
git fetch "$UPSTREAM_REMOTE" --tags 2>&1 || true

# Determine target
if [[ -z "$TARGET_TAG" ]]; then
    TARGET_TAG=$(git tag -l 'v*' --sort=-version:refname | head -1)
    info "No tag specified, using latest: $TARGET_TAG"
fi

if ! git rev-parse "$TARGET_TAG" >/dev/null 2>&1; then
    err "Tag $TARGET_TAG not found"
    exit 1
fi

# Find the upstream base of our current patches
# This is the most recent commit that exists in upstream
UPSTREAM_BASE=$(git merge-base HEAD "$UPSTREAM_REMOTE/main" 2>/dev/null || git merge-base HEAD "$TARGET_TAG")
PATCH_COUNT=$(git rev-list --count "$UPSTREAM_BASE..HEAD")
TARGET_COMMIT=$(git rev-parse "$TARGET_TAG")
CURRENT_BASE_TAG=$(git describe --tags --abbrev=0 "$UPSTREAM_BASE" 2>/dev/null || echo "unknown")

info "Current base: $CURRENT_BASE_TAG ($UPSTREAM_BASE)"
info "Target:       $TARGET_TAG ($TARGET_COMMIT)"
info "Patches:      $PATCH_COUNT Systivate commits to rebase"

if [[ "$UPSTREAM_BASE" == "$TARGET_COMMIT" ]]; then
    ok "Already on $TARGET_TAG — nothing to rebase"
    exit 0
fi

echo ""
info "Systivate patches to rebase:"
git log --oneline "$UPSTREAM_BASE..HEAD"

echo ""
info "Upstream changes ($CURRENT_BASE_TAG..$TARGET_TAG):"
UPSTREAM_CHANGES=$(git rev-list --count "$UPSTREAM_BASE..$TARGET_COMMIT")
echo "  $UPSTREAM_CHANGES commits"

# Check for overlapping files
echo ""
info "Conflict analysis:"
UPSTREAM_FILES=$(git diff --name-only "$UPSTREAM_BASE..$TARGET_COMMIT" | sort)
SYSTIVATE_FILES=$(git diff --name-only "$UPSTREAM_BASE..HEAD" | sort)
OVERLAP=$(comm -12 <(echo "$UPSTREAM_FILES") <(echo "$SYSTIVATE_FILES"))

if [[ -z "$OVERLAP" ]]; then
    ok "No overlapping files — rebase should be clean"
else
    warn "Overlapping files (may need manual resolution):"
    echo "$OVERLAP" | sed 's/^/    /'
fi

if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry run — stopping here"
    exit 0
fi

if [[ "$AUTO_YES" != "1" ]]; then
    echo ""
    read -p "Proceed with rebase onto $TARGET_TAG? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Aborted"
        exit 0
    fi
fi

# Create a backup branch before rebasing
BACKUP_BRANCH="systivate/pre-rebase-$(date +%Y%m%d-%H%M%S)"
info "Creating backup branch: $BACKUP_BRANCH"
git branch "$BACKUP_BRANCH"

# Rebase
info "Rebasing $PATCH_COUNT patches onto $TARGET_TAG..."
if git rebase --onto "$TARGET_TAG" "$UPSTREAM_BASE" "$BRANCH"; then
    ok "Rebase succeeded!"
    echo ""
    info "New commit history:"
    git log --oneline -$((PATCH_COUNT + 2))
else
    err "Rebase failed — conflicts need manual resolution"
    echo ""
    echo "  To continue after resolving:  git rebase --continue"
    echo "  To abort and restore:         git rebase --abort"
    echo "  Backup branch:                $BACKUP_BRANCH"
    exit 1
fi

# Push to fork
info "Pushing to $FORK_REMOTE..."
git push "$FORK_REMOTE" "$BRANCH" --force-with-lease

ok "Rebase complete. $BRANCH is now based on $TARGET_TAG"

# Build if requested
if [[ "$DO_BUILD" == "1" ]]; then
    echo ""
    info "Building Ghostty-Systivate..."

    # Zig build (fast verification)
    info "Step 1/3: Zig build verification..."
    if ! zig build -Dapp-runtime=none --summary all 2>&1 | tail -3; then
        err "Zig build failed"
        exit 1
    fi
    ok "Zig build passed"

    # Xcode build
    info "Step 2/3: Xcode Release build..."
    if ! xcodebuild -project macos/Ghostty.xcodeproj \
        -scheme Ghostty -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        DEVELOPMENT_TEAM="$DEV_TEAM" \
        CODE_SIGN_IDENTITY="Apple Development" 2>&1 | tail -5; then
        err "Xcode build failed"
        exit 1
    fi
    ok "Xcode build passed"

    # Verify code signing coherence before deploying
    info "Step 3/4: Verifying code signature coherence..."
    verify_codesign "$BUILD_DIR/Build/Products/Release/Ghostty.app"

    # Deploy — atomic swap to prevent SIGKILL (Code Signature Invalid)
    # on any running Ghostty-Systivate process. rm+cp is NOT atomic:
    # removing the old bundle unmaps code pages from running processes,
    # and macOS kills them with SIGKILL when a demand-paged code page
    # fails signature validation against the now-different binary.
    #
    # Strategy: cp to staging dir, then mv (atomic on same filesystem).
    info "Step 4/4: Deploying to $INSTALL_DIR..."
    STAGING="/Applications/.Ghostty-Systivate-staging.app"
    rm -rf "$STAGING"
    cp -R "$BUILD_DIR/Build/Products/Release/Ghostty.app" "$STAGING"

    # Verify staged copy before swapping
    NEW_HASH=$(md5 -q "$STAGING/Contents/MacOS/ghostty")
    BUILD_HASH=$(md5 -q "$BUILD_DIR/Build/Products/Release/Ghostty.app/Contents/MacOS/ghostty")
    if [[ "$NEW_HASH" != "$BUILD_HASH" ]]; then
        err "Hash mismatch after staging copy!"
        rm -rf "$STAGING"
        exit 1
    fi
    verify_codesign "$STAGING"

    # Atomic swap: mv the old out, mv the new in
    OLD_BACKUP="/Applications/.Ghostty-Systivate-old.app"
    rm -rf "$OLD_BACKUP"
    if [[ -d "$INSTALL_DIR" ]]; then
        mv "$INSTALL_DIR" "$OLD_BACKUP"
    fi
    mv "$STAGING" "$INSTALL_DIR"
    rm -rf "$OLD_BACKUP"

    ok "Deployed! Hash: $NEW_HASH"
    warn "Running Ghostty-Systivate still uses the old binary in memory."
    warn "Restart it to pick up the new build. (Old process is safe — not killed.)"
fi
