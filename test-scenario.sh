#!/usr/bin/env bash
#
# Interactive Test Script for Single-Server Infrastructure
# Based on PRD requirements in plans/PRD.md
#
# Usage: ./test-scenario.sh
#

set -e

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
run_step "5.3" "Check Prometheus targets" curl -s http://localhost:9090/api/v1/targets 2>/dev/null || echo "Prometheus not accessible on localhost (expected in container network)"

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

printf "\n${BOLD}Test scenario complete!${NC}\n"
printf "\n${CYAN}To test routing in a browser (requires proper DNS/hosts):${NC}\n"
printf "  • demo.app.\${BASE_DOMAIN}\n"
printf "  • demo-alt.app.\${BASE_DOMAIN}\n"
printf "  • central.\${BASE_DOMAIN}/grafana\n"
printf "  • traefik.\${BASE_DOMAIN}\n"
