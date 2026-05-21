#!/bin/bash

# ============================================================
# Jenkins Upgrade Automation Script
# ============================================================
# Purpose:
#   Automates Jenkins upgrade workflow:
#   - Stop backup sync
#   - Pull latest master
#   - Create upgrade branch
#   - Detect Jenkins version
#   - Build Docker image
#   - Push image to Nexus
#   - Update deployment.yaml
#   - Commit + Push branch
#
# Usage:
#   ./upgrade-jenkins.sh v20
#
# Example:
#   ./upgrade-jenkins.sh v20
#
# Final Image Tag:
#   2.528.3-v20
#
# ============================================================

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

REPO_DIR="$HOME/git/starboard"
DOCKER_DIR="$REPO_DIR/k8s/jenkins"
DEPLOYMENT_FILE="$DOCKER_DIR/deployment.yaml"

NEXUS_REPO="nexus.ndc.aptportfolio.com/sysops/jenkins"

BACKUP_SERVICE="jenkins-backup.service"

BASE_BRANCH="master"

# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================================
# FUNCTIONS
# ============================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

exit_error() {
    log_error "$1"
    exit 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || exit_error "$1 command not found"
}

cleanup() {
    log_warn "Cleanup triggered"

    if docker ps -a | grep -q temp-jenkins-version; then
        docker rm -f temp-jenkins-version >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

# ============================================================
# VALIDATION
# ============================================================

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 v<number>"
    echo "Example: $0 v20"
    exit 1
fi

CUSTOM_TAG="$1"

if [[ ! "$CUSTOM_TAG" =~ ^v[0-9]+$ ]]; then
    exit_error "Invalid tag format. Use: v20"
fi

# ============================================================
# PRECHECKS
# ============================================================

log_info "Running prechecks..."

check_command git
check_command docker
check_command sed
check_command systemctl

[[ -d "$REPO_DIR" ]] || exit_error "Repo directory not found: $REPO_DIR"
[[ -f "$DEPLOYMENT_FILE" ]] || exit_error "deployment.yaml not found"

cd "$REPO_DIR"

# Check git clean state
if [[ -n $(git status --porcelain) ]]; then
    exit_error "Git working tree is not clean. Commit/stash changes first."
fi

# ============================================================
# STOP BACKUP SERVICE
# ============================================================

log_info "Stopping backup sync service..."

if systemctl is-active --quiet "$BACKUP_SERVICE"; then
    sudo systemctl stop "$BACKUP_SERVICE" \
        || exit_error "Failed to stop $BACKUP_SERVICE"

    log_info "Backup service stopped"
else
    log_warn "$BACKUP_SERVICE already stopped"
fi

# ============================================================
# GIT OPERATIONS
# ============================================================

log_info "Pulling latest master branch..."

git checkout "$BASE_BRANCH" \
    || exit_error "Failed to checkout master"

git pull -r origin "$BASE_BRANCH" \
    || exit_error "Git pull failed"

# ============================================================
# DETECT JENKINS VERSION
# ============================================================

log_info "Detecting latest Jenkins LTS version..."

JENKINS_VERSION=$(docker run --rm jenkins/jenkins:lts \
bash -c "java -jar /usr/share/jenkins/jenkins.war --version" \
2>/dev/null)

if [[ -z "$JENKINS_VERSION" ]]; then
    exit_error "Unable to detect Jenkins version"
fi

log_info "Detected Jenkins Version: $JENKINS_VERSION"

FINAL_TAG="${JENKINS_VERSION}-${CUSTOM_TAG}"

log_info "Final Docker Tag: $FINAL_TAG"

# ============================================================
# CREATE BRANCH
# ============================================================

BRANCH_NAME="jenkins-upgrade-${FINAL_TAG}"

log_info "Creating branch: $BRANCH_NAME"

git checkout -b "$BRANCH_NAME" \
    || exit_error "Failed to create branch"

# ============================================================
# BUILD DOCKER IMAGE
# ============================================================

cd "$DOCKER_DIR"

log_info "Building Docker image..."

docker build . -t "jenkins:${FINAL_TAG}" \
    || exit_error "Docker build failed"

# ============================================================
# OPTIONAL LOCAL VALIDATION
# ============================================================

log_info "Running temporary validation container..."

docker run -d \
    --name temp-jenkins-version \
    -p 61535:8080 \
    "jenkins:${FINAL_TAG}" >/dev/null \
    || exit_error "Failed to start validation container"

sleep 15

if ! docker ps | grep -q temp-jenkins-version; then
    exit_error "Validation container crashed"
fi

log_info "Validation container started successfully"

docker rm -f temp-jenkins-version >/dev/null 2>&1 || true

# ============================================================
# TAG + PUSH IMAGE
# ============================================================

FULL_IMAGE="${NEXUS_REPO}:${FINAL_TAG}"

log_info "Tagging image..."

docker tag "jenkins:${FINAL_TAG}" "$FULL_IMAGE" \
    || exit_error "Docker tag failed"

log_info "Pushing image to Nexus..."

docker push "$FULL_IMAGE" \
    || exit_error "Docker push failed"

# ============================================================
# UPDATE deployment.yaml
# ============================================================

log_info "Updating deployment.yaml..."

cd "$REPO_DIR"

OLD_IMAGE=$(grep "image:" "$DEPLOYMENT_FILE" | awk '{print $2}')

sed -i "s|image: .*|image: ${FULL_IMAGE}|g" "$DEPLOYMENT_FILE" \
    || exit_error "Failed to update deployment.yaml"

NEW_IMAGE=$(grep "image:" "$DEPLOYMENT_FILE" | awk '{print $2}')

if [[ "$NEW_IMAGE" != "$FULL_IMAGE" ]]; then
    exit_error "deployment.yaml update verification failed"
fi

log_info "deployment.yaml updated successfully"

# ============================================================
# GIT COMMIT
# ============================================================

log_info "Committing changes..."

git add "$DEPLOYMENT_FILE"

git commit -m "Upgrade Jenkins to ${FINAL_TAG}" \
    || exit_error "Git commit failed"

# ============================================================
# PUSH BRANCH
# ============================================================

log_info "Pushing branch to remote..."

git push origin "$BRANCH_NAME" \
    || exit_error "Git push failed"

# ============================================================
# FINAL OUTPUT
# ============================================================

echo ""
echo "============================================================"
echo -e "${GREEN}JENKINS UPGRADE COMPLETED SUCCESSFULLY${NC}"
echo "============================================================"
echo ""
echo "Jenkins Version : $JENKINS_VERSION"
echo "Docker Tag      : $FINAL_TAG"
echo "Git Branch      : $BRANCH_NAME"
echo "Image           : $FULL_IMAGE"
echo ""

echo "NEXT STEPS:"
echo "1. Login to ArgoCD"
echo "2. Change revision/branch to:"
echo "   $BRANCH_NAME"
echo ""
echo "3. Validate Jenkins deployment"
echo "4. Merge PR to master"
echo "5. Change ArgoCD branch back to master"
echo "6. Start backup sync service"
echo ""

echo "Start backup service command:"
echo "sudo systemctl start $BACKUP_SERVICE"

echo ""
echo "============================================================"


