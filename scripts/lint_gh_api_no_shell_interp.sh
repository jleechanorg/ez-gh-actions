#!/usr/bin/env bash
# lint_gh_api_no_shell_interp.sh - reject inline shell-interpolated gh api bodies.
#
# GH#58 / bead jleechan-o9s8. While creating PR #56, a Markdown body
# containing backticks was interpolated into a shell-built gh api command
# via -f body="$BODY". The shell executed the backticked text, briefly
# starting the legacy Lima VM and embedding command output into the PR
# description. The safe pattern is
#   jq --rawfile BODY_FILE . | gh api --input -
# (or jq -Rs <<<"$BODY" | gh api --input -); see the GH#58 PR body for
# the full write-up.
#
# This lint scans shell scripts for gh api invocations of the form
#   gh api ... -f body=<value>
#   gh api ... --field body=<value>
# and flags them when <value> would be evaluated by the shell before it
# reaches gh. Two evaluation forms are dangerous:
#   (1) -f body=$(cmd)   or -f body=`cmd`  (direct interpolation)
#   (2) -f body="$VAR"   where VAR was previously assigned via $() or
#                        backticks in the same file (transitive risk)
# Comment lines (starting with a hash) and lines whose gh api text
# appears inside single quotes are skipped to avoid the most common
# false positives.
#
# Usage:
#   bash scripts/lint_gh_api_no_shell_interp.sh <scan-path> [<scan-path>...]
#   # or pass nothing: scans scripts/ tests/ install.sh .githooks/ by default
#
# Exit codes:
#   0 - no unsafe patterns found
#   1 - one or more unsafe patterns found (each emitted to stderr as
#       FAIL: <file>:<line>: unsafe shell-interpolated gh api body - use
#       'jq --rawfile BODY_FILE . | gh api --input -' instead)

set -u  # do NOT add -e or pipefail: we want to keep scanning after a hit

# Default scan targets if no paths were passed on the command line.
DEFAULT_TARGETS=(
  scripts
  tests
  install.sh
  .githooks
)

if [ "$#" -eq 0 ]; then
  set -- "${DEFAULT_TARGETS[@]}"
fi

FAILURES=0

emit_failure() {
  local file="$1"
  local lineno="$2"
  printf 'FAIL: %s:%s: unsafe shell-interpolated gh api body - use jq --rawfile BODY_FILE . | gh api --input - instead\n' \
    "$file" "$lineno" >&2
  FAILURES=$((FAILURES + 1))
}

# scan_file <path>
#
# We use awk to do both passes in one stream so dirty-var tracking is
# naturally line-local and we avoid two full file reads. The awk
# script:
#   - collects, into a "dirty_vars" set, every identifier that appears
#     on the LHS of an assignment whose RHS contains $( or a backtick
#   - for any line that contains "gh api" and a body field flag, emits
#     a failure if the line contains $( or a backtick, OR if it
#     interpolates any identifier already in dirty_vars.
#
# The awk script intentionally operates line-by-line; we do not track
# multi-line state, which matches how the dangerous pattern is written
# in real scripts (single line).
scan_file() {
  local file="$1"
  awk -v file="$file" '
    function emit_failure(lineno) {
      printf("FAIL: %s:%d: unsafe shell-interpolated gh api body - use jq --rawfile BODY_FILE . | gh api --input - instead\n", file, lineno) > "/dev/stderr"
      failures++
    }
    function is_comment(line,    t) {
      t = line
      sub(/^[[:space:]]+/, "", t)
      return (substr(t, 1, 1) == "#")
    }
    function single_quote_open(line,    n) {
      n = gsub(/'\''/, "'\''", line)
      return (n % 2 == 1)
    }
    function extract_dirty_vars(line,    n, i, m, var) {
      # Find every "<ws>export <ws>VAR[<ws>]=" pattern and check if
      # the RHS contains $( or backtick. Capture the var name.
      n = split(line, parts, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        var = parts[i]
        # Strip an "export=" prefix (rare but possible).
        if (var == "export" && i + 1 <= n) {
          i++
          var = parts[i]
        }
        # The token must end in =. Strip a leading identifier.
        if (match(var, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
          var = substr(var, 1, RSTART + RLENGTH - 2)
          # Grab the RHS by removing the LHS up to and including "=".
          rhs = substr(line, index(line, var "=") + length(var) + 1)
          if (rhs ~ /\$/ || index(rhs, "\140") > 0) {
            if (index(dirty, " " var " ") == 0) {
              dirty = dirty " " var " "
            }
          }
        }
      }
    }
    function check_line(line, lineno,    n, i, m, var, rest) {
      if (is_comment(line)) return
      if (line !~ /gh[ \t]+api/) return
      if (line !~ /-f[ \t]+body=/ && line !~ /--field[ \t]+body=/) return
      if (single_quote_open(line)) return

      # Direct interpolation: -f body=$(cmd) or -f body=`cmd` on the
      # same line. The body value can be inside double quotes, so
      # we check the line for $( or backtick ANYWHERE after the body=
      # flag - the shell will evaluate the substitution before gh
      # sees the body regardless of quoting.
      body_pos = index(line, "-f body=")
      if (body_pos == 0) body_pos = index(line, "--field body=")
      if (body_pos > 0) {
        after = substr(line, body_pos)
        if (after ~ /\$/ || index(after, "\140") > 0) {
          emit_failure(lineno); return
        }
      }

      # Transitive: -f body="$VAR" where VAR was assigned via $( or
      # backtick earlier in the file. Extract every "$VAR" substring
      # from the line and check the var name against the dirty set.
      # We use a manual scan instead of split() because awk split
      # treats the delimiters as separators, leaving the boundaries
      # attached to the wrong side of the array elements.
      rest = line
      while (match(rest, /"\$[A-Za-z_][A-Za-z0-9_]*"/)) {
        var = substr(rest, RSTART + 2, RLENGTH - 3)
        if (index(dirty, " " var " ") > 0) {
          emit_failure(lineno); return
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    BEGIN { dirty = " "; failures = 0 }
    {
      # Strip comments first - anything inside a # is not executable.
      # We do not strip inline comments (everything after #) because
      # the pattern we are looking for rarely appears inside a comment
      # tail; this is a known false-positive surface.
      line = $0
      lineno = NR

      # Pass 1: extract dirty var assignments.
      if (!is_comment(line)) {
        extract_dirty_vars(line)
      }

      # Pass 2: check the line itself.
      check_line(line, lineno)
    }
    END {
      exit (failures > 0 ? 1 : 0)
    }
  ' "$file"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILURES=$((FAILURES + 1))
  fi
}

# Walk every argument: if it is a directory, recurse one level into it
# looking for *.sh files; if it is a file, scan it directly. We do not
# follow symlinks.
for target in "$@"; do
  if [ -d "$target" ]; then
    # Find .sh files one level deep. Deeper recursion would catch
    # nested test fixtures (e.g. tests/host/) but also expands the
    # surface area for false positives; keep the surface narrow for
    # v1 and revisit if a real hit is missed.
    while IFS= read -r -d '' f; do
      scan_file "$f"
    done < <(find "$target" -maxdepth 2 -type f -name '*.sh' -print0 2>/dev/null)
  elif [ -f "$target" ]; then
    scan_file "$target"
  else
    printf 'lint_gh_api_no_shell_interp: skipping missing path: %s\n' "$target" >&2
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  printf 'lint_gh_api_no_shell_interp: %d unsafe pattern(s) found\n' "$FAILURES" >&2
  exit 1
fi

exit 0