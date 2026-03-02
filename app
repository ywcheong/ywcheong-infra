#!/usr/bin/env bash

set -e
set -o pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTRAL_INFRA_DIR="$INFRA_ROOT/central-infra"
APPS_DIR="$INFRA_ROOT/apps"
TEMPLATE_DIR="$INFRA_ROOT/template/app"
MAINTENANCE_TEMPLATE="$INFRA_ROOT/template/maintenance.yml"

if [ -t 1 ]; then
  COLOR_RED='\033[0;31m'
  COLOR_GREEN='\033[0;32m'
  COLOR_YELLOW='\033[1;33m'
  COLOR_BLUE='\033[0;34m'
  COLOR_RESET='\033[0m'
else
  COLOR_RED=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_BLUE=''
  COLOR_RESET=''
fi

info() {
  printf "%b[INFO]%b %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$1"
}

success() {
  printf "%b[OK]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

warn() {
  printf "%b[WARN]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$1"
}

error() {
  printf "%b[ERROR]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1" >&2
}

usage() {
  cat <<EOF
Usage: ./app <command> [arguments]

App lifecycle management CLI for single-server infrastructure.

Commands:
  create <name> <port>  Create new app scaffolding
                        - Validates name (lowercase letters, numbers, hyphens; must start with letter)
                        
  remove <name>         Remove an existing app
                        - Prompts for confirmation
                        - Stops containers via docker compose down
                        - Deletes app directory
                        - Central infra and other apps unaffected
                        
  start <name>          Start an app container
                        - Reads APP_PORT from apps/<name>/.env
                        - Starts via docker compose up -d
                        - Traefik auto-detects and enables routing
                        
  stop <name>           Stop an app container
                        - Stops via docker compose down
                        - Traefik auto-disables routing
                        - Does not remove app files
                        
  upgrade <name>        Perform zero-downtime upgrade
                        1. Enables maintenance page routing
                        2. Pulls latest image
                        3. Recreates container (no dependencies)
                        4. Restores normal routing (auto-cleanup on error)
                        
  list                  List all registered apps and their status
                        - Shows app name and container status
                        - Reads from apps/ directory
                        
  help                  Show this help message

Examples:
  ./app create myapp 8080
  ./app start myapp
  ./app upgrade myapp
  ./app remove myapp
  ./app list

Notes:
  - All compose commands use both ~/infra/.env and apps/<name>/.env
  - Domain routing uses {name}.app.\${BASE_DOMAIN}
  - App files never hardcode domain information
EOF
}

require_apps_dir() {
  if [ ! -d "$APPS_DIR" ]; then
    error "Apps directory not found: $APPS_DIR"
    exit 1
  fi
}

validate_name() {
  local app_name="$1"

  if [[ ! "$app_name" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
    error "Invalid app name '$app_name'. Use lowercase letters, numbers, and hyphens. Must start with a letter."
    exit 1
  fi
}

validate_port() {
  local port="$1"

  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    error "Invalid port '$port'. Must be a number."
    exit 1
  fi

  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    error "Invalid port '$port'. Must be between 1 and 65535."
    exit 1
  fi
}

ensure_app_exists() {
  local app_name="$1"
  local app_dir="$APPS_DIR/$app_name"

  if [ ! -d "$app_dir" ]; then
    error "App '$app_name' does not exist in $APPS_DIR"
    exit 1
  fi

  if [ ! -f "$app_dir/.env" ]; then
    error "Missing env file: $app_dir/.env"
    exit 1
  fi

  if [ ! -f "$app_dir/compose.base.yml" ]; then
    error "Missing compose file: $app_dir/compose.base.yml"
    exit 1
  fi

  if [ ! -f "$app_dir/compose.attach.yml" ]; then
    error "Missing compose file: $app_dir/compose.attach.yml"
    exit 1
  fi
}

read_env_value() {
  local env_file="$1"
  local key="$2"

  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    case "$k" in
      "#"*)
        continue
        ;;
      "$key")
        printf "%s" "$v"
        return 0
        ;;
    esac
  done < "$env_file"

  return 1
}

# Required environment variables for root .env
REQUIRED_ROOT_ENV_VARS=(
  "BASE_DOMAIN"
)

# Required environment variables for app .env
REQUIRED_APP_ENV_VARS=(
  "APP_NAME"
  "APP_PORT"
)

# Validate root environment file has required variables
validate_root_env() {
  local env_file="$INFRA_ROOT/.env"
  local missing_vars=()
  local var_name var_value

  if [[ ! -f "$env_file" ]]; then
    error "Root environment file not found: $env_file"
    error "Run './infra setup' first"
    exit 1
  fi

  for var_name in "${REQUIRED_ROOT_ENV_VARS[@]}"; do
    if ! var_value=$(read_env_value "$env_file" "$var_name") || [[ -z "$var_value" ]]; then
      missing_vars+=("$var_name")
    fi
  done

  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    error "Missing required environment variables in root .env:"
    for var_name in "${missing_vars[@]}"; do
      printf "  - %s\n" "$var_name" >&2
    done
    exit 1
  fi
}

# Validate app environment file has required variables
validate_app_env() {
  local app_dir="$1"
  local env_file="$app_dir/.env"
  local missing_vars=()
  local var_name var_value

  if [[ ! -f "$env_file" ]]; then
    error "App environment file not found: $env_file"
    exit 1
  fi

  for var_name in "${REQUIRED_APP_ENV_VARS[@]}"; do
    if ! var_value=$(read_env_value "$env_file" "$var_name") || [[ -z "$var_value" ]]; then
      missing_vars+=("$var_name")
    fi
  done

  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    error "Missing required environment variables in $env_file:"
    for var_name in "${missing_vars[@]}"; do
      printf "  - %s\n" "$var_name" >&2
    done
    exit 1
  fi
}

compose_app() {
  local app_name="$1"
  shift

  local app_dir="$APPS_DIR/$app_name"

  docker compose \
    --env-file "$INFRA_ROOT/.env" \
    --env-file "$app_dir/.env" \
    -f "$app_dir/compose.base.yml" \
    -f "$app_dir/compose.attach.yml" \
    "$@"
}

generate_maintenance_yaml() {
  local app_name="$1"
  local base_domain

  if [ ! -f "$MAINTENANCE_TEMPLATE" ]; then
    error "Maintenance template not found: $MAINTENANCE_TEMPLATE"
    exit 1
  fi

  if ! base_domain="$(read_env_value "$INFRA_ROOT/.env" "BASE_DOMAIN")"; then
    error "BASE_DOMAIN is missing in $INFRA_ROOT/.env"
    exit 1
  fi

  sed -e "s/\${APP_NAME}/$app_name/g" \
      -e "s/\${BASE_DOMAIN}/$base_domain/g" \
      "$MAINTENANCE_TEMPLATE"
}

create_app() {
  local app_name="$1"
  local app_port="$2"
  local app_dir="$APPS_DIR/$app_name"

  require_apps_dir
  validate_name "$app_name"
  validate_port "$app_port"

  if [ -d "$app_dir" ]; then
    error "App '$app_name' already exists at $app_dir"
    exit 1
  fi

  if [ ! -d "$TEMPLATE_DIR" ]; then
    error "Template directory not found: $TEMPLATE_DIR"
    exit 1
  fi

  if [ ! -f "$TEMPLATE_DIR/.env" ]; then
    error "Template .env not found: $TEMPLATE_DIR/.env"
    exit 1
  fi

  if [ ! -f "$TEMPLATE_DIR/compose.base.yml" ]; then
    error "Template compose.base.yml not found: $TEMPLATE_DIR/compose.base.yml"
    exit 1
  fi

  if [ ! -f "$TEMPLATE_DIR/compose.attach.yml" ]; then
    error "Template compose.attach.yml not found: $TEMPLATE_DIR/compose.attach.yml"
    exit 1
  fi

  mkdir -p "$app_dir"

  # Copy template files
  cp "$TEMPLATE_DIR/.env" "$app_dir/.env"
  cp "$TEMPLATE_DIR/compose.base.yml" "$app_dir/compose.base.yml"
  cp "$TEMPLATE_DIR/compose.attach.yml" "$app_dir/compose.attach.yml"

  # Replace placeholders with actual values
  sed -i "s/\${APP_NAME}/$app_name/g" "$app_dir/.env"
  sed -i "s/\${APP_PORT}/$app_port/g" "$app_dir/.env"

  success "App '$app_name' scaffolded in $app_dir"
  info "Next steps:"
  printf "  1) Edit %s/compose.base.yml with your image and config\n" "$app_dir"
  printf "  2) Start app: ./app start %s\n" "$app_name"
}

remove_app() {
  local app_name="$1"
  local app_dir="$APPS_DIR/$app_name"
  local reply

  require_apps_dir
  ensure_app_exists "$app_name"

  read -r -p "Remove app '$app_name'? This will run docker compose down and delete $app_dir [y/N]: " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    warn "Removal cancelled."
    exit 0
  fi

  info "Stopping app '$app_name'"
  compose_app "$app_name" down

  rm -rf "$app_dir"
  success "App '$app_name' removed."
}

start_app() {
  local app_name="$1"
  local app_dir="$APPS_DIR/$app_name"
  local app_port

  require_apps_dir
  ensure_app_exists "$app_name"
  validate_root_env
  validate_app_env "$app_dir"

  if ! app_port="$(read_env_value "$app_dir/.env" "APP_PORT")"; then
    error "APP_PORT is missing in $app_dir/.env"
    exit 1
  fi

  validate_port "$app_port"

  info "Starting app '$app_name' on port $app_port"
  compose_app "$app_name" up -d
  success "App '$app_name' started."
}

stop_app() {
  local app_name="$1"

  require_apps_dir
  ensure_app_exists "$app_name"

  info "Stopping app '$app_name'"
  compose_app "$app_name" down
  success "App '$app_name' stopped."
}

upgrade_app() {
  local app_name="$1"
  local app_dir="$APPS_DIR/$app_name"
  local maintenance_file="$CENTRAL_INFRA_DIR/traefik/dynamic/maintenance-${app_name}.yml"

  require_apps_dir
  ensure_app_exists "$app_name"
  validate_root_env
  validate_app_env "$app_dir"

  info "Enabling maintenance routing for '$app_name'"
  generate_maintenance_yaml "$app_name" > "$maintenance_file"
  sleep 1

  trap "rm -f '$maintenance_file'" EXIT

  info "Pulling latest image for '$app_name'"
  compose_app "$app_name" pull

  info "Recreating app container"
  compose_app "$app_name" up -d --no-deps "app-server"

  success "Upgrade complete for '$app_name'. Maintenance routing will be removed on exit."
}

list_apps() {
  local found=0
  local app_name

  require_apps_dir
  printf "%-24s %-12s\n" "APP" "STATUS"

  for app_dir in "$APPS_DIR"/*; do
    [ -d "$app_dir" ] || continue
    app_name="$(basename "$app_dir")"
    found=1

    local container_name="${app_name}-app-server-1"
    local status

    status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
    if [ "$status" = "running" ]; then
      status="running"
    elif [ -z "$status" ]; then
      status="stopped"
    else
      status="stopped"
    fi

    printf "%-24s %-12s\n" "$app_name" "$status"
  done

  if [ "$found" -eq 0 ]; then
    warn "No apps registered in $APPS_DIR"
  fi
}

main() {
  local command="${1:-help}"

  case "$command" in
    create)
      [ "$#" -eq 3 ] || { usage; exit 1; }
      create_app "$2" "$3"
      ;;
    remove)
      [ "$#" -eq 2 ] || { usage; exit 1; }
      remove_app "$2"
      ;;
    start)
      [ "$#" -eq 2 ] || { usage; exit 1; }
      start_app "$2"
      ;;
    stop)
      [ "$#" -eq 2 ] || { usage; exit 1; }
      stop_app "$2"
      ;;
    upgrade)
      [ "$#" -eq 2 ] || { usage; exit 1; }
      upgrade_app "$2"
      ;;
    list)
      [ "$#" -eq 1 ] || { usage; exit 1; }
      list_apps
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      error "Unknown command: $command"
      usage
      exit 1
      ;;
  esac
}

main "$@"
