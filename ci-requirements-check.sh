#!/usr/bin/env bash
#
# CI Requirements Checker (parallel)
#
# Runs each requirement through Claude CLI in parallel to verify compliance.
# A live TUI shows real-time progress as each check completes.
#
# Usage:
#   ./scripts/ci-requirements-check.sh <requirements-file> [--project-dir <path>]
#   echo "requirement text" | ./scripts/ci-requirements-check.sh - [--project-dir <path>]
#
# Requirements file format: one requirement per line (blank lines and #-comments are skipped).
#
# Exit code: 0 if all requirements pass, 1 if any fails, 2 on usage error.

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"

# ── colors & symbols ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; DIM='\033[2m'
  BOLD='\033[1m'; RESET='\033[0m'; CLEAR_LINE='\033[2K'
  SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  SYM_OK='✓'; SYM_FAIL='✗'; SYM_WAIT='○'
  IS_TTY=true
else
  GREEN=''; RED=''; YELLOW=''; DIM=''; BOLD=''; RESET=''; CLEAR_LINE=''
  SPINNER_FRAMES=('-')
  SYM_OK='OK'; SYM_FAIL='FAIL'; SYM_WAIT='-'
  IS_TTY=false
fi

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <requirements-file | -> [--project-dir <path>]"
  echo ""
  echo "  <requirements-file>  Path to a file with one requirement per line."
  echo "  -                    Read requirements from stdin."
  echo "  --project-dir        Project directory for Claude context (default: git root)."
  exit 2
}

# ── parse args ────────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage

INPUT_FILE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
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

# Pass 1: classify lines into (parent, child[]) groups
# - Lines starting with "- " are children of the preceding non-child line
# - Non-child, non-blank, non-comment lines are parents (context providers)
# - A parent with no children becomes a standalone requirement

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
    # child: strip "- " prefix, prepend parent context for prompt
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
    # new parent: flush previous if it had no children
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

# Count unique parent groups (for board_lines calculation)
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

# status files: $WORK_DIR/<idx>.status  = PENDING | RUNNING | OK | FAIL
#               $WORK_DIR/<idx>.reason  = reason text
#               $WORK_DIR/<idx>.elapsed = seconds taken

for i in "${!requirements[@]}"; do
  echo "PENDING" > "$WORK_DIR/$i.status"
  echo ""        > "$WORK_DIR/$i.reason"
done

# ── worker function (runs in background) ─────────────────────────────────────
run_check() {
  local idx="$1"
  local req="$2"
  local start_time=$SECONDS

  echo "RUNNING" > "$WORK_DIR/$idx.status"

  local prompt
  prompt="$(build_prompt "$req")"

  local raw_output=""
  if raw_output=$("$CLAUDE_CMD" -p "$prompt" -d "$PROJECT_DIR" --output-format text 2>&1); then
    local status_line
    status_line=$(echo "$raw_output" | grep -E '^STATUS:\s*(OK|FAIL)\s*\|' | tail -1 || true)

    if [[ -n "$status_line" ]]; then
      local status reason
      status=$(echo "$status_line" | sed -E 's/^STATUS:\s*(OK|FAIL)\s*\|.*/\1/')
      reason=$(echo "$status_line" | sed -E 's/^STATUS:\s*(OK|FAIL)\s*\|\s*REASON:\s*//')

      echo "$status" > "$WORK_DIR/$idx.status"
      echo "$reason"  > "$WORK_DIR/$idx.reason"
    else
      local short_output
      short_output=$(echo "$raw_output" | head -3 | tr '\n' ' ' | cut -c1-200)
      echo "FAIL" > "$WORK_DIR/$idx.status"
      echo "(unparseable response) $short_output" > "$WORK_DIR/$idx.reason"
    fi
  else
    echo "FAIL" > "$WORK_DIR/$idx.status"
    echo "(claude cli error) $(echo "$raw_output" | head -1 | cut -c1-200)" > "$WORK_DIR/$idx.reason"
  fi

  echo "$(( SECONDS - start_time ))" > "$WORK_DIR/$idx.elapsed"
}

# ── TUI rendering ────────────────────────────────────────────────────────────
#
# Renders the full status board. In TTY mode, uses ANSI escape codes to
# overwrite previous output for a live-updating display.

render_board() {
  local spin_frame="$1"
  local completed="$2"
  local output=""

  # Move cursor up to overwrite (only after first render)
  # Each requirement = 2 lines (name + reason), plus parent header lines,
  # plus 1 progress bar + 1 blank line
  # Standalone requirements (no parent) count as 0 extra header lines
  local board_lines=$(( total * 2 + num_groups + 2 ))
  if [[ "$IS_TTY" == true && "$FIRST_RENDER_DONE" == true ]]; then
    output+="\033[${board_lines}A"
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

    # Print parent header when entering a new group
    if [[ -n "$par" && "$par" != "$last_parent" ]]; then
      output+="${CLEAR_LINE}  ${BOLD}${par}${RESET}\n"
      last_parent="$par"
    elif [[ -z "$par" ]]; then
      last_parent="_NONE_"
    fi

    # Indentation: nested children get extra indent
    local indent="  "
    local reason_indent="     "
    if [[ -n "$par" ]]; then
      indent="    "
      reason_indent="       "
    fi

    # Truncate display text
    local max_req_len=66
    [[ -n "$par" ]] && max_req_len=64
    local short_req="$display"
    if [[ ${#short_req} -gt $max_req_len ]]; then
      short_req="${short_req:0:$max_req_len}…"
    fi

    local line="${CLEAR_LINE}"
    case "$st" in
      OK)
        local time_str=""
        [[ -n "$elapsed" ]] && time_str=" ${DIM}(${elapsed}s)${RESET}"
        line+="${indent}${GREEN}${SYM_OK}${RESET} ${BOLD}#${idx}${RESET} ${short_req}${time_str}\n"
        line+="${CLEAR_LINE}${reason_indent}${GREEN}${reason}${RESET}"
        ;;
      FAIL)
        local time_str=""
        [[ -n "$elapsed" ]] && time_str=" ${DIM}(${elapsed}s)${RESET}"
        line+="${indent}${RED}${SYM_FAIL}${RESET} ${BOLD}#${idx}${RESET} ${short_req}${time_str}\n"
        line+="${CLEAR_LINE}${reason_indent}${RED}${reason}${RESET}"
        ;;
      RUNNING)
        local spinner="${SPINNER_FRAMES[$spin_frame]}"
        line+="${indent}${YELLOW}${spinner}${RESET} ${BOLD}#${idx}${RESET} ${short_req} ${DIM}running…${RESET}\n"
        line+="${CLEAR_LINE}${reason_indent}${DIM}waiting for result${RESET}"
        ;;
      PENDING)
        line+="${indent}${DIM}${SYM_WAIT}${RESET} ${BOLD}#${idx}${RESET} ${DIM}${short_req}${RESET}\n"
        line+="${CLEAR_LINE}"
        ;;
    esac
    output+="${line}\n"
  done

  echo -ne "$output"
  FIRST_RENDER_DONE=true
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

  # Print parent header on group change
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
FIRST_RENDER_DONE=false
spin=0

if [[ "$IS_TTY" == true ]]; then
  # Initial render
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
  # Non-TTY: wait for each, print as done
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
