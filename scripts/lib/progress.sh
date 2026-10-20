# shellcheck shell=bash
# Sourced, not run. A one-line progress bar for steps that cannot say how far
# they have got.
#
# The map setup is one long run of SQL files, and some single statements in it
# take minutes, so nothing in it can report a fraction. What is reliable is
# that a step prints the same lines in the same order every run. So while a
# step runs, its timeline -- when its log reached each line count -- is
# written beside the log, and the next run reads the last successful run's
# timeline: being at line n now is being where that run was at time t(n),
# which is t(n) / total of the way through. The time left is scaled by how
# fast this run reached line n compared with that one. With no earlier run to
# go by, the bar runs on a typical duration and stops short of the end.
#
# Drawn only on a terminal; anywhere else the caller prints plain lines.

progress_enabled() {
  [[ -t 1 && "${TERM:-dumb}" != dumb ]]
}

progress_columns() {
  local cols
  cols="$(tput cols 2>/dev/null || true)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="${COLUMNS:-80}"
  echo "$cols"
}

# progress_format_seconds N -> "45s", "12m", "1h05m"
progress_format_seconds() {
  local s="$1"
  if (( s < 60 )); then
    printf '%ds' "$s"
  elif (( s < 3600 )); then
    printf '%dm' $(( (s + 30) / 60 ))
  else
    printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# progress_draw "label" PERMILLE "right-hand text" -- redraws the current line.
# PERMILLE is 0..1000; a negative one draws no bar (unknown progress).
progress_draw() {
  local label="$1" permille="$2" text="$3"
  local cols bar_width filled bar="" i pct room
  cols="$(progress_columns)"
  bar_width=24
  (( cols < 70 )) && bar_width=12
  if (( permille >= 0 )); then
    (( permille > 1000 )) && permille=1000
    filled=$(( permille * bar_width / 1000 ))
    for (( i = 0; i < bar_width; i++ )); do
      if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    pct="$(printf '%3d%%' $(( permille / 10 )))"
    bar="${bar} ${pct}"
  fi
  # label column + bar + its percentage, then whatever room is left for text
  room=$(( cols - 2 - 27 - (permille >= 0 ? bar_width + 6 : 0) - 1 ))
  (( room < 0 )) && room=0
  printf '\r\033[K  %-26s %s  %s' "$label" "$bar" "${text:0:room}"
}

progress_clear() {
  printf '\r\033[K'
}

# progress_estimate PREV_TIMELINE PREV_TOTAL LINES ELAPSED REACHED_AT
#   PREV_TIMELINE  "seconds lines" per row, from an earlier run of the step
#   PREV_TOTAL     that run's duration in seconds
#   LINES          lines in this run's log now
#   ELAPSED        seconds since this run's step started
#   REACHED_AT     elapsed seconds when this run's log reached LINES
# prints "PERMILLE SECONDS_LEFT"
progress_estimate() {
  awk -v total="$2" -v lines="$3" -v elapsed="$4" -v reached="$5" '
    { t[NR] = $1; n[NR] = $2 }
    END {
      if (total <= 0) { print -1, -1; exit }
      tc = -1; tnext = total
      for (i = 1; i <= NR; i++) {
        if (tc < 0 && n[i] >= lines) tc = t[i]
        if (n[i] > lines) { tnext = t[i]; break }
      }
      if (lines == 0) tc = 0
      if (tc < 0) tc = total                 # past every line that run printed
      stay = elapsed - reached               # how long this run has sat on this line
      window = tnext - tc
      if (stay > window) stay = window
      pos = tc + stay
      speed = 1
      if (tc >= 10 && reached > 0) speed = reached / tc
      if (speed < 0.33) speed = 0.33
      if (speed > 3) speed = 3
      left = (total - pos) * speed
      if (left < 0) left = 0
      permille = int(pos * 1000 / total)
      if (permille > 990) permille = 990
      printf "%d %d\n", permille, left
    }' "$1"
}

# The fallback when no earlier run of a step left a timeline: how long each
# step took on the development machine.
progress_typical_seconds() {
  case "$1" in
    backup) echo 5 ;;
    load) echo 35 ;;
    metadata) echo 10 ;;
    restore) echo 15 ;;
    map|map_restore) echo 1200 ;;
    *) echo 60 ;;
  esac
}

# The last line of a step's log that says what it is doing -- the scripts
# announce each phase as "Doing something..." -- without its dots.
progress_activity() {
  local line
  line="$(grep -E '\.\.\.[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 || true)"
  line="${line%%...*}"
  printf '%s' "${line#"${line%%[![:space:]]*}"}"
}
