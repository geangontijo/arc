#!/usr/bin/env bash
#
# CI Requirements Checker (parallel)
#
# Runs each requirement through Claude CLI in parallel to verify compliance.
# A live TUI shows real-time progress with streaming output per requirement.
#
# Usage:
#   arc <requirements-file> [--project-dir <path>] [--agent <name>]
#   echo "requirement text" | arc - [--project-dir <path>] [--agent <name>]
#
# --agent <name>     Force a specific code agent. One of: claude, opencode, agy, antigravity.
#                    Overrides the CLAUDE_CMD env var and the auto-detected default.
#
# Requirements file format: one requirement per line (blank lines and #-comments are skipped).
# Supports nested format — see "read requirements" section below.
#
# Exit code: 0 if all requirements pass, 1 if any fails, 2 on usage error.

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Auto-detect defaults: opencode (preferred) -> agy -> claude
DEFAULT_CMD="claude"
if command -v opencode >/dev/null 2>&1; then
  DEFAULT_CMD="opencode"
elif command -v agy >/dev/null 2>&1; then
  DEFAULT_CMD="agy"
elif command -v antigravity >/dev/null 2>&1; then
  DEFAULT_CMD="antigravity"
fi

CLAUDE_CMD="${CLAUDE_CMD:-$DEFAULT_CMD}"
OUTPUT_WINDOW=${OUTPUT_WINDOW:-10}

# Determine the type of the CLI (opencode, agy, or claude)
detect_cli_type() {
  local cmd="$1"
  local exe
  exe=$(echo "$cmd" | awk '{print $1}')
  local cmd_name
  cmd_name=$(basename "$exe")
  if [[ "$cmd_name" == "opencode" ]]; then
    echo "opencode"
  elif [[ "$cmd_name" == "agy" || "$cmd_name" == "antigravity" ]]; then
    echo "agy"
  elif [[ "$cmd_name" == "claude" ]]; then
    echo "claude"
  else
    # Fallback to inspecting help output or checking names
    if "$exe" --help 2>&1 | grep -q "Usage of agy:"; then
      echo "agy"
    elif "$exe" --help 2>&1 | grep -q "opencode"; then
      echo "opencode"
    else
      echo "claude"
    fi
  fi
}

CLI_TYPE=$(detect_cli_type "$CLAUDE_CMD")

# ── colors & symbols ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; DIM='\033[2m'
  BOLD='\033[1m'; RESET='\033[0m'; CLEAR_LINE='\033[2K'; CLEAR_BELOW='\033[J'
  SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  SYM_OK='✓'; SYM_FAIL='✗'; SYM_WAIT='○'
  IS_TTY=true
else
  GREEN=''; RED=''; YELLOW=''; DIM=''; BOLD=''; RESET=''; CLEAR_LINE=''; CLEAR_BELOW=''
  SPINNER_FRAMES=('-')
  SYM_OK='OK'; SYM_FAIL='FAIL'; SYM_WAIT='-'
  IS_TTY=false
fi

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <requirements-file | -> [--project-dir <path>] [--agent <name>]"
  echo ""
  echo "  <requirements-file>  Path to a file with one requirement per line."
  echo "  -                    Read requirements from stdin."
  echo "  --project-dir        Project directory for the agent context (default: git root)."
  echo "  --agent <name>       Force a specific code agent: claude, opencode, agy, antigravity."
  echo "                       Overrides CLAUDE_CMD and the auto-detected default."
  exit 2
}

# ── parse args ────────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage

INPUT_FILE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --agent)
      AGENT_NAME="${2,,}"
      case "$AGENT_NAME" in
        claude|opencode|agy|antigravity) CLAUDE_CMD="$AGENT_NAME" ;;
        *) echo "Error: unknown agent '$2'. Valid agents: claude, opencode, agy, antigravity."; exit 2 ;;
      esac
      shift 2
      ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ── read requirements ─────────────────────────────────────────────────────────
# Supports nested format where parent lines provide context for child lines:
#
#   The alb-openresty build
#   - are running on ARM?
#   - are using centralized cache?
#
# Produces:
#   "The alb-openresty build are running on ARM?"
#   "The alb-openresty build are using centralized cache?"
#
# Flat lines (no parent) are treated as standalone requirements.

raw_lines=()
if [[ "$INPUT_FILE" == "-" ]]; then
  while IFS= read -r line; do
    raw_lines+=("$line")
  done
else
  [[ ! -f "$INPUT_FILE" ]] && { echo "Error: file not found: $INPUT_FILE"; exit 2; }
  while IFS= read -r line; do
    raw_lines+=("$line")
  done < "$INPUT_FILE"
fi

# Arrays:
#   requirements[i] = full prompt text (parent + child merged)
#   req_parent[i]   = parent context for display ("" if standalone)
#   req_child[i]    = child text for display (or full text if standalone)
#   group_order[]   = ordered list of unique parent strings (for rendering)

requirements=()
req_parent=()
req_child=()
group_order=()
parent=""
parent_used=false

flush_parent() {
  if [[ -n "$parent" && "$parent_used" == false ]]; then
    requirements+=("$parent")
    req_parent+=("")
    req_child+=("$parent")
  fi
}

for line in "${raw_lines[@]}"; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

  if [[ "$trimmed" == -* ]]; then
    child="${trimmed#-}"
    child="${child#"${child%%[![:space:]]*}"}"
    if [[ -n "$parent" ]]; then
      requirements+=("${parent} ${child}")
      req_parent+=("$parent")
      req_child+=("$child")
      if [[ "$parent_used" == false ]]; then
        group_order+=("$parent")
      fi
      parent_used=true
    else
      requirements+=("$child")
      req_parent+=("")
      req_child+=("$child")
    fi
  else
    flush_parent
    parent="$trimmed"
    parent_used=false
  fi
done
flush_parent

if [[ ${#requirements[@]} -eq 0 ]]; then
  echo "Error: no requirements found in input."
  exit 2
fi

total=${#requirements[@]}
num_groups=${#group_order[@]}

# ── prompt template ───────────────────────────────────────────────────────────
build_prompt() {
  local requirement="$1"
  cat <<PROMPT
This is a CI step. You are a requirements auditor. Analyze the codebase to determine whether the following requirement is satisfied.

Requirement: "${requirement}"

Instructions:
1. Search the codebase thoroughly for evidence that the requirement is or is not met.
2. Respond with EXACTLY one line in this format (no markdown, no extra text):
   STATUS: OK | REASON: <short confirmation of what satisfies the requirement>
   or
   STATUS: FAIL | REASON: <short explanation of why it fails>
3. The STATUS field must be exactly "OK" or "FAIL".
4. The REASON must be a single line, max 200 characters.
5. Do NOT output anything else — no preamble, no markdown fences, no extra lines.
PROMPT
}

# ── temp dir for results ─────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Files per requirement:
#   $WORK_DIR/<idx>.status  = PENDING | RUNNING | OK | FAIL
#   $WORK_DIR/<idx>.reason  = reason text
#   $WORK_DIR/<idx>.elapsed = seconds taken
#   $WORK_DIR/<idx>.output  = streaming claude CLI output

for i in "${!requirements[@]}"; do
  echo "PENDING" > "$WORK_DIR/$i.status"
  echo ""        > "$WORK_DIR/$i.reason"
  touch "$WORK_DIR/$i.output"
done

# ── stream event processor ────────────────────────────────────────────────────
# Converts stream-json events into human-readable lines for the output window.
# Reads JSON lines from stdin, writes readable lines to stdout.
process_stream() {
  while IFS= read -r json_line; do
    # Skip empty lines
    [[ -z "$json_line" ]] && continue

    local event_type
    event_type=$(echo "$json_line" | jq -r '.type // empty' 2>/dev/null) || continue

    case "$event_type" in
      assistant)
        # Extract content blocks from the message
        local content_types
        content_types=$(echo "$json_line" | jq -r '.message.content[]?.type // empty' 2>/dev/null) || continue

        for ctype in $content_types; do
          case "$ctype" in
            thinking)
              local thinking
              thinking=$(echo "$json_line" | jq -r '.message.content[] | select(.type=="thinking") | .thinking // empty' 2>/dev/null)
              [[ -n "$thinking" ]] && echo "[thinking] $thinking"
              ;;
            tool_use)
              local tool_name tool_input
              tool_name=$(echo "$json_line" | jq -r '.message.content[] | select(.type=="tool_use") | .name // empty' 2>/dev/null)
              tool_input=$(echo "$json_line" | jq -r '.message.content[] | select(.type=="tool_use") | .input | to_entries | map(.key + "=" + (.value | tostring | .[0:60])) | join(", ")' 2>/dev/null)
              [[ -n "$tool_name" ]] && echo "[tool] ${tool_name}(${tool_input})"
              ;;
            text)
              local text
              text=$(echo "$json_line" | jq -r '.message.content[] | select(.type=="text") | .text // empty' 2>/dev/null)
              [[ -n "$text" ]] && echo "[output] $text"
              ;;
          esac
        done
        ;;
      user)
        # Tool results
        local has_tool_result
        has_tool_result=$(echo "$json_line" | jq -r '.message.content[]?.type // empty' 2>/dev/null | grep -c tool_result || true)
        if [[ "$has_tool_result" -gt 0 ]]; then
          local tool_id duration
          tool_id=$(echo "$json_line" | jq -r '.message.content[0].tool_use_id // empty' 2>/dev/null)
          duration=$(echo "$json_line" | jq -r '.tool_use_result.durationMs // empty' 2>/dev/null)
          local result_summary
          result_summary=$(echo "$json_line" | jq -r '
            .tool_use_result |
            if .filenames then
              (.filenames | length | tostring) + " file(s) found"
            elif .numFiles then
              (.numFiles | tostring) + " file(s)"
            else
              "done"
            end
          ' 2>/dev/null)
          local time_info=""
          [[ -n "$duration" && "$duration" != "null" ]] && time_info=" (${duration}ms)"
          echo "[result] ${result_summary}${time_info}"
        fi
        ;;
    esac
  done
}

# ── worker function (runs in background) ─────────────────────────────────────
run_check() {
  local idx="$1"
  local req="$2"
  local start_time=$SECONDS

  echo "RUNNING" > "$WORK_DIR/$idx.status"

  local prompt
  prompt="$(build_prompt "$req")"

  local exit_code=0

  if [[ "$CLI_TYPE" == "opencode" ]]; then
    # opencode uses subcommand `run` and passes the message positionally.
    # `--dir` sets the working directory; `--dangerously-skip-permissions`
    # auto-approves tool calls so the run is non-interactive.
    # Both stdout and stderr are captured for the live output window.
    $CLAUDE_CMD run "$prompt" --dir "$PROJECT_DIR" --dangerously-skip-permissions > "$WORK_DIR/$idx.output" 2>&1 || exit_code=$?

    # Strip ANSI escape sequences so the STATUS line parses reliably.
    local status_line
    status_line=$(sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$WORK_DIR/$idx.output" \
      | grep -E 'STATUS:[[:space:]]*(OK|FAIL)[[:space:]]*\|' | tail -1 || true)

    if [[ $exit_code -eq 0 && -n "$status_line" ]]; then
      local status reason
      status=$(echo "$status_line" | sed -E 's/.*STATUS:[[:space:]]*(OK|FAIL)[[:space:]]*\|.*/\1/')
      reason=$(echo "$status_line" | sed -E 's/.*STATUS:[[:space:]]*(OK|FAIL)[[:space:]]*\|[[:space:]]*REASON:[[:space:]]*//')

      echo "$status" > "$WORK_DIR/$idx.status"
      echo "$reason"  > "$WORK_DIR/$idx.reason"
    elif [[ $exit_code -ne 0 ]]; then
      local error_text
      error_text=$(tail -n 5 "$WORK_DIR/$idx.output" | tr '\n' ' ' | cut -c1-200)
      echo "FAIL" > "$WORK_DIR/$idx.status"
      echo "(opencode cli error) ${error_text:-unknown error}" > "$WORK_DIR/$idx.reason"
    else
      local short_output
      short_output=$(tail -n 3 "$WORK_DIR/$idx.output" | tr '\n' ' ' | cut -c1-200)
      echo "FAIL" > "$WORK_DIR/$idx.status"
      echo "(unparseable response) $short_output" > "$WORK_DIR/$idx.reason"
    fi
  elif [[ "$CLI_TYPE" == "agy" ]]; then
    # agy runs in print mode with --dangerously-skip-permissions, directing output/thoughts to stdout/stderr.
    # We pipe both stdout and stderr to the output file so the TUI can show real-time stream.
    $CLAUDE_CMD -p "$prompt" --add-dir "$PROJECT_DIR" --dangerously-skip-permissions > "$WORK_DIR/$idx.output" 2>&1 || exit_code=$?

    # For agy, the raw output is the final output file.
    local status_line
    status_line=$(grep -E 'STATUS:\s*(OK|FAIL)\s*\|' "$WORK_DIR/$idx.output" | tail -1 || true)

    if [[ $exit_code -eq 0 && -n "$status_line" ]]; then
      local status reason
      status=$(echo "$status_line" | sed -E 's/.*STATUS:\s*(OK|FAIL)\s*\|.*/\1/')
      reason=$(echo "$status_line" | sed -E 's/.*STATUS:\s*(OK|FAIL)\s*\|\s*REASON:\s*//')

      echo "$status" > "$WORK_DIR/$idx.status"
      echo "$reason"  > "$WORK_DIR/$idx.reason"
    elif [[ $exit_code -ne 0 ]]; then
      local error_text
      error_text=$(tail -n 5 "$WORK_DIR/$idx.output" | tr '\n' ' ' | cut -c1-200)
      echo "FAIL" > "$WORK_DIR/$idx.status"
      echo "(agy cli error) ${error_text:-unknown error}" > "$WORK_DIR/$idx.reason"
    else
      local short_output
      short_output=$(tail -n 3 "$WORK_DIR/$idx.output" | tr '\n' ' ' | cut -c1-200)
      echo "FAIL" > "$WORK_DIR/$idx.status"
      echo "(unparseable response) $short_output" > "$WORK_DIR/$idx.reason"
    fi
  else
    # Stream JSON events, process into readable lines for the TUI,
    # and also capture raw JSON for status parsing at the end.
    "$CLAUDE_CMD" -p "$prompt" -d "$PROJECT_DIR" \
      --output-format stream-json --verbose 2>&1 \
      | tee "$WORK_DIR/$idx.raw" \
      | process_stream \
      > "$WORK_DIR/$idx.output" || exit_code=$?

    # Parse the result event from raw JSON for the STATUS line
    local result_text
    result_text=$(jq -r 'select(.type=="result") | .result // empty' "$WORK_DIR/$idx.raw" 2>/dev/null || true)

    if [[ $exit_code -eq 0 && -n "$result_text" ]]; then
      local status_line
      status_line=$(echo "$result_text" | grep -E '^STATUS:\s*(OK|FAIL)\s*\|' | tail -1 || true)

      if [[ -n "$status_line" ]]; then
        local status reason
        status=$(echo "$status_line" | sed -E 's/^STATUS:\s*(OK|FAIL)\s*\|.*/\1/')
        reason=$(echo "$status_line" | sed -E 's/^STATUS:\s*(OK|FAIL)\s*\|\s*REASON:\s*//')

        echo "$status" > "$WORK_DIR/$idx.status"
        echo "$reason"  > "$WORK_DIR/$idx.reason"
      else
        local short_output
        short_output=$(echo "$result_text" | head -3 | tr '\n' ' ' | cut -c1-200)
        echo "FAIL" > "$WORK_DIR/$idx.status"
        echo "(unparseable response) $short_output" > "$WORK_DIR/$idx.reason"
      fi
    else
      local error_text
      error_text=$(jq -r 'select(.type=="result") | .result // empty' "$WORK_DIR/$idx.raw" 2>/dev/null || true)
      echo "FAIL" > "$WORK_DIR/$idx.status"
      echo "(claude cli error) $(echo "${error_text:-unknown error}" | head -1 | cut -c1-200)" > "$WORK_DIR/$idx.reason"
    fi
  fi

  echo "$(( SECONDS - start_time ))" > "$WORK_DIR/$idx.elapsed"
}

# ── TUI rendering ────────────────────────────────────────────────────────────
#
# Dynamic-height board: RUNNING items show a live output window, completed
# items collapse to 2 lines. We track the previous render's line count and
# use \033[J (clear below) to handle shrinking output.

LAST_RENDER_LINES=0

render_board() {
  local spin_frame="$1"
  local completed="$2"
  local output=""
  local line_count=0
  local term_width
  term_width=$(tput cols 2>/dev/null || echo 120)

  # Move cursor up to overwrite previous render
  if [[ "$IS_TTY" == true && $LAST_RENDER_LINES -gt 0 ]]; then
    output+="\033[${LAST_RENDER_LINES}A"
  fi

  # Progress bar
  local bar_width=40
  local filled=$(( completed * bar_width / total ))
  local empty=$(( bar_width - filled ))
  local bar=""
  for ((b=0; b<filled; b++)); do bar+="█"; done
  for ((b=0; b<empty; b++));  do bar+="░"; done

  output+="${CLEAR_LINE}  ${DIM}${bar} ${completed}/${total} completed${RESET}\n"
  output+="${CLEAR_LINE}\n"
  line_count=$((line_count + 2))

  # Requirement rows — grouped by parent
  local last_parent="_NONE_"

  for i in "${!requirements[@]}"; do
    local display="${req_child[$i]}"
    local par="${req_parent[$i]}"
    local idx=$((i + 1))
    local st
    st=$(<"$WORK_DIR/$i.status")
    local reason=""
    [[ -f "$WORK_DIR/$i.reason" ]] && reason=$(<"$WORK_DIR/$i.reason")
    local elapsed=""
    [[ -f "$WORK_DIR/$i.elapsed" ]] && elapsed=$(<"$WORK_DIR/$i.elapsed")

    # Print parent header when entering a new group (truncated to term width to prevent wrapping)
    if [[ -n "$par" && "$par" != "$last_parent" ]]; then
      local max_par_width=$(( term_width - 4 ))
      [[ $max_par_width -lt 20 ]] && max_par_width=20
      local short_par="$par"
      if [[ ${#short_par} -gt $max_par_width ]]; then
        short_par="${short_par:0:$max_par_width}…"
      fi
      output+="${CLEAR_LINE}  ${BOLD}${short_par}${RESET}\n"
      last_parent="$par"
      line_count=$((line_count + 1))
    elif [[ -z "$par" ]]; then
      last_parent="_NONE_"
    fi

    # Indentation
    local indent="  "
    local out_indent="     "
    if [[ -n "$par" ]]; then
      indent="    "
      out_indent="       "
    fi

    # Truncate display text dynamically based on terminal width.
    # The widest line format is RUNNING: indent + spinner + " #NN " + req + " running…"
    # indent_len + 1(spinner) + 1(space) + 1(#) + ${#idx} + 1(space) + req + 1(space) + 10("running…")
    local indent_len=${#indent}
    local idx_len=${#idx}
    local fixed_overhead=$(( indent_len + 1 + 1 + 1 + idx_len + 1 + 1 + 10 ))
    local max_req_len=$(( term_width - fixed_overhead ))
    [[ $max_req_len -lt 20 ]] && max_req_len=20
    local short_req="$display"
    if [[ ${#short_req} -gt $max_req_len ]]; then
      short_req="${short_req:0:$max_req_len}…"
    fi

    # Max width for output window lines
    local out_prefix_len=${#out_indent}
    # +4 for "╎ " prefix
    local max_out_width=$(( term_width - out_prefix_len - 4 ))
    [[ $max_out_width -lt 20 ]] && max_out_width=20

    # Max width for reason line to prevent wrapping and progress bar duplication
    local max_reason_width=$(( term_width - out_prefix_len - 2 ))
    [[ $max_reason_width -lt 20 ]] && max_reason_width=20
    local short_reason="$reason"
    if [[ ${#short_reason} -gt $max_reason_width ]]; then
      short_reason="${short_reason:0:$max_reason_width}…"
    fi

    case "$st" in
      OK)
        local time_str=""
        [[ -n "$elapsed" ]] && time_str=" ${DIM}(${elapsed}s)${RESET}"
        output+="${CLEAR_LINE}${indent}${GREEN}${SYM_OK}${RESET} ${BOLD}#${idx}${RESET} ${short_req}${time_str}\n"
        output+="${CLEAR_LINE}${out_indent}${GREEN}${short_reason}${RESET}\n"
        line_count=$((line_count + 2))
        ;;
      FAIL)
        local time_str=""
        [[ -n "$elapsed" ]] && time_str=" ${DIM}(${elapsed}s)${RESET}"
        output+="${CLEAR_LINE}${indent}${RED}${SYM_FAIL}${RESET} ${BOLD}#${idx}${RESET} ${short_req}${time_str}\n"
        output+="${CLEAR_LINE}${out_indent}${RED}${short_reason}${RESET}\n"
        line_count=$((line_count + 2))
        ;;
      RUNNING)
        local spinner="${SPINNER_FRAMES[$spin_frame]}"
        output+="${CLEAR_LINE}${indent}${YELLOW}${spinner}${RESET} ${BOLD}#${idx}${RESET} ${short_req} ${DIM}running…${RESET}\n"
        line_count=$((line_count + 1))

        # Live output window: last N lines from the streaming output file
        local out_lines=()
        if [[ -s "$WORK_DIR/$i.output" ]]; then
          while IFS= read -r oline; do
            out_lines+=("$oline")
          done < <(tail -n "$OUTPUT_WINDOW" "$WORK_DIR/$i.output" 2>/dev/null || true)
        fi

        local out_count=${#out_lines[@]}
        if [[ $out_count -gt 0 ]]; then
          for oline in "${out_lines[@]}"; do
            # Truncate long lines
            local truncated="$oline"
            if [[ ${#truncated} -gt $max_out_width ]]; then
              truncated="${truncated:0:$max_out_width}…"
            fi
            output+="${CLEAR_LINE}${out_indent}${DIM}╎ ${truncated}${RESET}\n"
            line_count=$((line_count + 1))
          done
        else
          output+="${CLEAR_LINE}${out_indent}${DIM}╎ waiting for output…${RESET}\n"
          line_count=$((line_count + 1))
        fi
        ;;
      PENDING)
        output+="${CLEAR_LINE}${indent}${DIM}${SYM_WAIT}${RESET} ${BOLD}#${idx}${RESET} ${DIM}${short_req}${RESET}\n"
        line_count=$((line_count + 1))
        ;;
    esac
  done

  # Clear any leftover lines from a previous taller render
  output+="${CLEAR_BELOW}"

  echo -ne "$output"
  LAST_RENDER_LINES=$line_count
}

# ── non-TTY fallback (print as each finishes) ────────────────────────────────
nontty_last_parent="_NONE_"

print_result_line() {
  local idx="$1"
  local display="${req_child[$idx]}"
  local par="${req_parent[$idx]}"
  local num=$((idx + 1))
  local st=$(<"$WORK_DIR/$idx.status")
  local reason=$(<"$WORK_DIR/$idx.reason")

  if [[ -n "$par" && "$par" != "$nontty_last_parent" ]]; then
    echo "  ${par}"
    nontty_last_parent="$par"
  elif [[ -z "$par" ]]; then
    nontty_last_parent="_NONE_"
  fi

  local indent="  "
  local reason_indent="     "
  if [[ -n "$par" ]]; then
    indent="    "
    reason_indent="       "
  fi

  if [[ "$st" == "OK" ]]; then
    echo "${indent}${SYM_OK} #${num} ${display}"
    echo "${reason_indent}${reason}"
  else
    echo "${indent}${SYM_FAIL} #${num} ${display}"
    echo "${reason_indent}${reason}"
  fi
}

# ── main: launch all checks in parallel ──────────────────────────────────────
pids=()

# Print header
echo -e "${BOLD}Requirements Check${RESET}"
echo -e "${BOLD}$(printf '=%.0s' {1..60})${RESET}"
echo -e "Project: ${PROJECT_DIR}"
echo -e "Agent: ${CLAUDE_CMD} ${DIM}(${CLI_TYPE})${RESET}"
echo -e "Requirements: ${total} ${DIM}(parallel)${RESET}"
echo -e "${BOLD}$(printf '=%.0s' {1..60})${RESET}"

# Hide cursor during TUI
if [[ "$IS_TTY" == true ]]; then
  tput civis 2>/dev/null || true
  restore_cursor() { tput cnorm 2>/dev/null || true; }
  trap 'restore_cursor; rm -rf "$WORK_DIR"' EXIT
fi

# Launch all workers
for i in "${!requirements[@]}"; do
  run_check "$i" "${requirements[$i]}" &
  pids+=($!)
done

# ── event loop: refresh TUI until all done ────────────────────────────────────
spin=0

if [[ "$IS_TTY" == true ]]; then
  render_board $spin 0

  while true; do
    completed=0
    for i in "${!requirements[@]}"; do
      local_st=$(<"$WORK_DIR/$i.status")
      [[ "$local_st" == "OK" || "$local_st" == "FAIL" ]] && ((completed++)) || true
    done

    spin=$(( (spin + 1) % ${#SPINNER_FRAMES[@]} ))
    render_board "$spin" "$completed"

    [[ $completed -eq $total ]] && break
    sleep 0.15
  done
else
  echo ""
  for i in "${!requirements[@]}"; do
    wait "${pids[$i]}" 2>/dev/null || true
    print_result_line "$i"
  done
fi

# Wait for all background processes to finish
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

echo ""

# ── summary ───────────────────────────────────────────────────────────────────
passed=0; failed=0

for i in "${!requirements[@]}"; do
  st=$(<"$WORK_DIR/$i.status")
  if [[ "$st" == "OK" ]]; then
    ((passed++)) || true
  else
    ((failed++)) || true
  fi
done

echo -e "${BOLD}$(printf '=%.0s' {1..60})${RESET}"
echo -e "${BOLD}Summary${RESET}"
echo -e "  Total:  ${total}"
echo -e "  ${GREEN}Passed: ${passed}${RESET}"
echo -e "  ${RED}Failed: ${failed}${RESET}"
echo -e "${BOLD}$(printf '=%.0s' {1..60})${RESET}"

if [[ $failed -gt 0 ]]; then
  echo ""
  echo -e "${RED}${BOLD}RESULT: FAILED${RESET} — ${failed} requirement(s) not met."
  exit 1
else
  echo ""
  echo -e "${GREEN}${BOLD}RESULT: PASSED${RESET} — all ${total} requirement(s) met."
  exit 0
fi
