# shellcheck shell=bash
# Sourced, not run. Runs helper programs (Python, pdftotext, Node) in the
# `tools` container (tools/Containerfile) instead of on the host.
#
# The repository is mounted at /work and is the container's working directory,
# so a path handed to a tool must be inside the repository: tool_path turns a
# host path into the container's, and tool_tmpdir makes scratch space where the
# container can see it (state/tmp/, ignored by git). stdin is passed through,
# so `run_tool python3 - "$file" <<'PY'` works as it would on the host.

TOOLS_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

run_tool() {
  # What a compose run says about itself rather than about the tool, dropped so
  # it does not land in the middle of a report: podman's wrapper adds "Error:
  # executing <provider> ... exit status N" whenever the tool exits non-zero,
  # and ">>>> Executing external compose provider ... <<<<" (plus a blank line)
  # before every call unless told not to; Compose v1 adds "Creating
  # <project>_tools_run ... done". The tool's own stderr and the exit status
  # are kept.
  (cd "$TOOLS_ROOT_DIR" && PODMAN_COMPOSE_WARNING_LOGS=false \
    podman compose --profile setup run --rm --no-deps -T tools "$@" \
    2> >(grep -Ev -e '^Error: executing .* exit status [0-9]+[[:space:]]*$' \
                  -e '^>>>> Executing external compose provider .*<<<<[[:space:]]*$' \
                  -e '^Creating [^ ]+_run( \.\.\.( done)?)?[[:space:]]*$' \
                  -e '^[[:space:]]*$' >&2))
}

tool_path() {
  local path
  path="$(realpath -m -- "$1")"
  case "$path" in
    "$TOOLS_ROOT_DIR") echo /work ;;
    "$TOOLS_ROOT_DIR"/*) echo "/work/${path#"$TOOLS_ROOT_DIR"/}" ;;
    *)
      echo "tool_path: $1 is outside ${TOOLS_ROOT_DIR}, where the tools container cannot see it" >&2
      return 1
      ;;
  esac
}

tool_tmpdir() {
  mkdir -p "${TOOLS_ROOT_DIR}/state/tmp"
  mktemp -d -p "${TOOLS_ROOT_DIR}/state/tmp"
}

# Builds the image if it is missing, so its build output lands here rather
# than in the middle of whatever the first tool call prints.
ensure_tools_image() {
  (cd "$TOOLS_ROOT_DIR" && podman image exists localhost/demscore-tools:2) && return 0
  echo "Building the tools image (tools/Containerfile), once..."
  (cd "$TOOLS_ROOT_DIR" && podman compose --profile setup build tools)
}
