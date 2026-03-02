#!/usr/bin/env bash
#
# Interactive Test Script for Single-Server Infrastructure
# Based on PRD requirements in plans/PRD.md
#
# Usage: ./test-scenario.sh
#

# set -e removed - interactive scripts need graceful error handling

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT"

# Colors
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  BOLD=''
  NC=''
fi

# State tracking
SKIPPED_STEPS=()
COMPLETED_STEPS=()
FAILED_STEPS=()

# Read BASE_DOMAIN from .env
get_base_domain() {
  local env_file="$INFRA_ROOT/.env"
  if [ -f "$env_file" ]; then
    grep -E "^BASE_DOMAIN=" "$env_file" | cut -d'=' -f2
  else
    echo "example.com"
  fi
}

BASE_DOMAIN="$(get_base_domain)"

# Print section header
section() {
  printf "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
  printf "${BOLD}${CYAN}  %s${NC}\n" "$1"
  printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n\n"
}

# Print step info
step() {
  local num="$1"
  local desc="$2"
  printf "${BOLD}${BLUE}[Step %s]${NC} %s\n" "$num" "$desc"
}

# Print command to be executed
show_cmd() {
  printf "\n${YELLOW}Command to execute:${NC}\n"
  printf "  ${BOLD}%s${NC}\n\n" "$*"
}

# Ask user for confirmation
# Returns: 0 = proceed, 1 = abort, 2 = skip
confirm() {
  local answer=""
  while true; do
    printf "${BOLD}Proceed?${NC} [${GREEN}y${NC}/${RED}n${NC}/${YELLOW}s${NC}] (y): "
    read -r answer
    case "$answer" in
      y|Y|yes|YES|"")
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      s|S|skip|SKIP)
        return 2
        ;;
      *)
        printf "Invalid input. Use 'y' (proceed), 'n' (abort), or 's' (skip).\n"
        ;;
    esac
  done
}

# Open URL in browser
open_url() {
  local url="$1"
  printf "${CYAN}Opening: %s${NC}\n" "$url"
  if command -v xdg-open &>/dev/null; then
    xdg-open "$url" 2>/dev/null &
  elif command -v google-chrome &>/dev/null; then
    google-chrome "$url" 2>/dev/null &
  elif command -v chromium &>/dev/null; then
    chromium "$url" 2>/dev/null &
  elif command -v open &>/dev/null; then
    open "$url" 2>/dev/null &
  else
    printf "${YELLOW}No browser found. Please open manually: %s${NC}\n" "$url"
  fi
}

# Execute command with user confirmation
run_step() {
  local step_num="$1"
  local description="$2"
  shift 2
  local cmd=("$@")

  step "$step_num" "$description"
  show_cmd "${cmd[*]}"

  confirm
  local result=$?

  case $result in
    0)
      printf "${GREEN}Executing...${NC}\n\n"
      if "${cmd[@]}"; then
        COMPLETED_STEPS+=("$step_num")
        printf "\n${GREEN}✓ Step %s completed successfully${NC}\n" "$step_num"
      else
        FAILED_STEPS+=("$step_num")
        printf "\n${RED}✗ Step %s FAILED${NC}\n" "$step_num"
        return 1
      fi
      ;;
    1)
      printf "${RED}Aborting test scenario.${NC}\n"
      exit 1
      ;;
    2)
      SKIPPED_STEPS+=("$step_num")
      printf "${YELLOW}⊘ Step %s skipped${NC}\n" "$step_num"
      ;;
  esac

  return 0
}

# Execute command without confirmation (for verification steps)
run_silent() {
  local description="$1"
  shift
  local cmd=("$@")

  printf "  → %s\n" "$description"
  if "${cmd[@]}" >/dev/null 2>&1; then
    printf "    ${GREEN}OK${NC}\n"
    return 0
  else
    printf "    ${RED}FAILED${NC}\n"
    return 1
  fi
}

# Print summary at the end
print_summary() {
  section "Test Summary"

  printf "${GREEN}Completed steps:${NC} %d\n" "${#COMPLETED_STEPS[@]}"
  if [ ${#COMPLETED_STEPS[@]} -gt 0 ]; then
    printf "  %s\n" "${COMPLETED_STEPS[*]}"
  fi

  printf "\n${YELLOW}Skipped steps:${NC} %d\n" "${#SKIPPED_STEPS[@]}"
  if [ ${#SKIPPED_STEPS[@]} -gt 0 ]; then
    printf "  %s\n" "${SKIPPED_STEPS[*]}"
  fi

  printf "\n${RED}Failed steps:${NC} %d\n" "${#FAILED_STEPS[@]}"
  if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    printf "  %s\n" "${FAILED_STEPS[*]}"
  fi

  if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    printf "\n${BOLD}${GREEN}All steps completed successfully!${NC}\n"
  else
    printf "\n${BOLD}${RED}Some steps failed. Please review the output above.${NC}\n"
  fi
}

# Cleanup function
cleanup() {
  printf "\n${YELLOW}Cleaning up...${NC}\n"
  print_summary
}

trap cleanup EXIT

# ============================================================================
# TEST SCENARIOS BASED ON PRD REQUIREMENTS
# ============================================================================

section "PRD Test Scenarios - Single Server Infrastructure"

printf "This script tests the following PRD requirements:\n"
printf "  • Central infrastructure + multiple apps on single machine\n"
printf "  • App lifecycle: create, start, stop, remove\n"
printf "  • Routing: each app accessible via unique subdomain\n"
printf "  • Idempotent operations\n"
printf "  • Infrastructure status and monitoring\n\n"

printf "${BOLD}Press Enter to start...${NC}"
read -r

# ----------------------------------------------------------------------------
# PHASE 1: Infrastructure Setup
# ----------------------------------------------------------------------------
section "Phase 1: Infrastructure Setup"

run_step "1.1" "Setup infrastructure prerequisites" ./infra setup
run_step "1.2" "Verify central-net network exists" docker network inspect central-net
run_step "1.3" "Start central infrastructure" ./infra start

# Wait for services to be ready
printf "\n${YELLOW}Waiting 10 seconds for services to initialize...${NC}\n"
sleep 10

run_step "1.4" "Check infrastructure status" ./infra status

# ----------------------------------------------------------------------------
# PHASE 2: App Creation and Lifecycle
# ----------------------------------------------------------------------------
section "Phase 2: App Creation and Lifecycle"

# Demo app already created, but we verify the structure
run_step "2.1" "Verify demo app structure" ls -la apps/demo/
run_step "2.2" "Verify demo-alt app structure" ls -la apps/demo-alt/
run_step "2.3" "List registered apps" ./app list

# ----------------------------------------------------------------------------
# PHASE 3: App Deployment and Routing
# ----------------------------------------------------------------------------
section "Phase 3: App Deployment and Routing"

run_step "3.1" "Start demo app" ./app start demo
run_step "3.2" "Start demo-alt app" ./app start demo-alt

printf "\n${YELLOW}Waiting 5 seconds for apps to be ready...${NC}\n"
sleep 5

run_step "3.3" "Check app status after start" ./app list

# Verify routing (requires network access)
run_step "3.4" "Check if demo container is running" docker ps --filter "name=demo" --format "table {{.Names}}\t{{.Status}}"
run_step "3.5" "Check if demo-alt container is running" docker ps --filter "name=demo-alt" --format "table {{.Names}}\t{{.Status}}"

# ----------------------------------------------------------------------------
# PHASE 3.6: Dynamic App Lifecycle (Live Add/Remove)
# ----------------------------------------------------------------------------
section "Phase 3.6: Dynamic App Lifecycle"

TEST_APP_NAME="test-live-$$"
TEST_APP_PORT=8099

printf "${CYAN}This phase tests creating, deploying, and removing a new app dynamically.${NC}\n"
printf "${CYAN}Test app name: %s (port %d)${NC}\n\n" "$TEST_APP_NAME" "$TEST_APP_PORT"

run_step "3.6.1" "Create new test app" ./app create "$TEST_APP_NAME" "$TEST_APP_PORT"

# Update compose.base.yml with nginx image
step "3.6.2" "Configure test app with nginx image"
show_cmd "sed -i 's/your-image:latest/nginx:alpine/' apps/$TEST_APP_NAME/compose.base.yml"
confirm
if [ $? -eq 0 ]; then
  sed -i 's/your-image:latest/nginx:alpine/' "apps/$TEST_APP_NAME/compose.base.yml"
  # Add custom index.html
  mkdir -p "apps/$TEST_APP_NAME/html"
  echo "<html><body><h1>Test App: $TEST_APP_NAME</h1><p>Dynamic app creation test successful!</p></body></html>" > "apps/$TEST_APP_NAME/html/index.html"
  # Update compose to mount html
  cat >> "apps/$TEST_APP_NAME/compose.base.yml" <<EOF
    volumes:
      - ./html:/usr/share/nginx/html:ro
EOF
  printf "${GREEN}✓ Step 3.6.2 completed successfully${NC}\n"
  COMPLETED_STEPS+=("3.6.2")
fi

run_step "3.6.3" "Start test app" ./app start "$TEST_APP_NAME"

printf "\n${YELLOW}Waiting 3 seconds for test app to be ready...${NC}\n"
sleep 3

run_step "3.6.4" "Verify test app is running" ./app list

step "3.6.5" "Open test app in browser"
printf "${CYAN}Opening test app URL in browser...${NC}\n"
open_url "https://${TEST_APP_NAME}.app.${BASE_DOMAIN}"
printf "${BOLD}Verify the test app is accessible. Press Enter to continue...${NC}"
read -r
COMPLETED_STEPS+=("3.6.5")

run_step "3.6.6" "Stop test app" ./app stop "$TEST_APP_NAME"

run_step "3.6.7" "Remove test app" rm -rf "apps/$TEST_APP_NAME"

printf "${GREEN}✓ Dynamic app lifecycle test complete${NC}\n\n"
# PHASE 4: App Management Operations
# ----------------------------------------------------------------------------
section "Phase 4: App Management Operations"

run_step "4.1" "Stop demo-alt app" ./app stop demo-alt
run_step "4.2" "Verify demo-alt is stopped" ./app list
run_step "4.3" "Verify demo is still running" docker ps --filter "name=demo" --format "table {{.Names}}\t{{.Status}}"

# Note: Skipping remove step to preserve test apps
# run_step "4.4" "Remove demo-alt app" ./app remove demo-alt

# ----------------------------------------------------------------------------
# PHASE 5: Infrastructure Status and Monitoring
# ----------------------------------------------------------------------------
section "Phase 5: Infrastructure Status and Monitoring"

run_step "5.1" "Full infrastructure status" ./infra status
run_step "5.2" "Check Traefik is routing" docker logs central-traefik --tail 20
run_step "5.3" "Check Prometheus targets" curl -sk "https://central.${BASE_DOMAIN}/prometheus/api/v1/targets" 2>/dev/null || echo "Prometheus not accessible via Traefik (check certificate/DNS)"

# ----------------------------------------------------------------------------
# PHASE 5.5: Browser URL Verification
# ----------------------------------------------------------------------------
section "Phase 5.5: Browser URL Verification"

printf "${CYAN}This phase opens browser URLs for manual verification.${NC}\n"
printf "${CYAN}Please verify each page loads correctly.${NC}\n\n"

step "5.5.1" "Open Grafana dashboard"
open_url "https://central.${BASE_DOMAIN}/grafana"
printf "${BOLD}Login: admin / password from .env (GF_SECURITY_ADMIN_PASSWORD)${NC}\n"
printf "${BOLD}Verify Grafana loads. Press Enter to continue...${NC}"
read -r
COMPLETED_STEPS+=("5.5.1")

step "5.5.2" "Open Traefik dashboard"
open_url "https://traefik.${BASE_DOMAIN}"
printf "${BOLD}Verify Traefik dashboard shows routers and services.${NC}\n"
printf "${BOLD}Press Enter to continue...${NC}"
read -r
COMPLETED_STEPS+=("5.5.2")

step "5.5.3" "Open demo app"
open_url "https://demo.app.${BASE_DOMAIN}"
printf "${BOLD}Verify demo app is accessible.${NC}\n"
printf "${BOLD}Press Enter to continue...${NC}"
read -r
COMPLETED_STEPS+=("5.5.3")

printf "${GREEN}✓ Browser verification complete${NC}\n\n"
# ----------------------------------------------------------------------------
# PHASE 6: Cleanup (Optional)
# ----------------------------------------------------------------------------
section "Phase 6: Cleanup (Optional)"

printf "${YELLOW}The following steps will stop all services.${NC}\n"
printf "${YELLOW}Skip these if you want to keep services running.${NC}\n\n"

run_step "6.1" "Stop demo app" ./app stop demo
run_step "6.2" "Stop central infrastructure" ./infra stop

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
print_summary

printf "\n${BOLD}${GREEN}Test scenario complete!${NC}\n"
printf "\n${CYAN}Tested URLs:${NC}\n"
printf "  • https://demo.app.%s\n" "$BASE_DOMAIN"
printf "  • https://central.%s/grafana\n" "$BASE_DOMAIN"
printf "  • https://traefik.%s\n" "$BASE_DOMAIN"
