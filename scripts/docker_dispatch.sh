#!/bin/bash
# Docker-based dispatch script with 3-tier fallback strategy
# Priority: Docker (preferred) > non-root user > su fallback

set -e

# Parse arguments
TASK_ID=""
PROMPT_FILE=""
ALLOWED_TOOLS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --task-id)
      TASK_ID="$2"
      shift 2
      ;;
    --prompt-file)
      PROMPT_FILE="$2"
      shift 2
      ;;
    --allowed-tools)
      ALLOWED_TOOLS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$TASK_ID" ]] || [[ -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 --task-id <id> --prompt-file <file> [--allowed-tools <tools>]"
  exit 1
fi

# Ensure log directory exists
mkdir -p .manus/logs

LOG_FILE=".manus/logs/${TASK_ID}.log"
EXIT_FILE=".manus/logs/${TASK_ID}.exit"

# Check if Docker is available
docker_info=$(docker info 2>&1)
if echo "$docker_info" | grep -q "Server Version"; then
  # Docker available - run in container as UID 1000
  echo "[dispatch] Running via Docker (non-root UID 1000)"

  DOCKER_CMD="docker run --rm"
  DOCKER_CMD+=" -i"
  DOCKER_CMD+=" -v $(pwd):/workspace"
  DOCKER_CMD+=" -v ~/.claude:/home/claude-runner/.claude:ro"
  DOCKER_CMD+=" -e ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  DOCKER_CMD+=" -e ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-}"
  DOCKER_CMD+=" claude-runner"

  if [[ -n "$ALLOWED_TOOLS" ]]; then
    $DOCKER_CMD claude -p "$(cat "$PROMPT_FILE")" --allowed-tools "$ALLOWED_TOOLS" --output-format json > "$LOG_FILE" 2>&1
  else
    $DOCKER_CMD claude -p "$(cat "$PROMPT_FILE")" --output-format json > "$LOG_FILE" 2>&1
  fi

  EXIT_CODE=$?
  echo "$EXIT_CODE" > "$EXIT_FILE"
  echo "[dispatch] Task ${TASK_ID} completed with exit code ${EXIT_CODE}"
  exit $EXIT_CODE

elif [[ $(id -u) -ne 0 ]]; then
  # Not root, no Docker - run directly
  echo "[dispatch] Docker unavailable, running as current user (non-root)"
  echo "[dispatch] WARNING: Running without Docker may have limited permissions"

  if [[ -n "$ALLOWED_TOOLS" ]]; then
    claude -p "$(cat "$PROMPT_FILE")" --allowed-tools "$ALLOWED_TOOLS" --output-format json > "$LOG_FILE" 2>&1
  else
    claude -p "$(cat "$PROMPT_FILE")" --output-format json > "$LOG_FILE" 2>&1
  fi

  EXIT_CODE=$?
  echo "$EXIT_CODE" > "$EXIT_FILE"
  echo "[dispatch] Task ${TASK_ID} completed with exit code ${EXIT_CODE}"
  exit $EXIT_CODE

else
  # Root user, no Docker - fallback to su
  echo "[dispatch] Docker unavailable, running as root"
  echo "[dispatch] WARNING: Falling back to su - this is NOT recommended"
  echo "[dispatch] WARNING: --dangerously-skip-permissions is disabled for root"

  if command -v claude-runner &>/dev/null; then
    su -s /bin/bash claude-runner -c "
      if [[ -n \"$ALLOWED_TOOLS\" ]]; then
        claude -p \"\$(cat '$PROMPT_FILE')\" --allowed-tools \"$ALLOWED_TOOLS\" --output-format json > '$LOG_FILE' 2>&1
      else
        claude -p \"\$(cat '$PROMPT_FILE')\" --output-format json > '$LOG_FILE' 2>&1
      fi
    "
  else
    # claude-runner user exists but claude CLI may not be in PATH for that user
    su -s /bin/bash claude-runner -c "
      export PATH=\$HOME/.local/bin:\$PATH:\$(npm root -g)
      if [[ -n \"$ALLOWED_TOOLS\" ]]; then
        claude -p \"\$(cat '$PROMPT_FILE')\" --allowed-tools \"$ALLOWED_TOOLS\" --output-format json > '$LOG_FILE' 2>&1
      else
        claude -p \"\$(cat '$PROMPT_FILE')\" --output-format json > '$LOG_FILE' 2>&1
      fi
    "
  fi

  EXIT_CODE=$?
  echo "$EXIT_CODE" > "$EXIT_FILE"
  echo "[dispatch] Task ${TASK_ID} completed with exit code ${EXIT_CODE}"
  exit $EXIT_CODE
fi
