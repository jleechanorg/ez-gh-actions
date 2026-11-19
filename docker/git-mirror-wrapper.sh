#!/usr/bin/env bash
# ezgha git mirror wrapper: transparently hydrates fresh GitHub Actions
# runner repositories from a read-only host git mirror mounted at
# EZGHA_GIT_MIRRORS before running `git fetch`.
#
# Installed at /usr/local/bin/git (ahead of /usr/bin/git in PATH).
# Fails open on any missing mirror, unrecognized remote, or local write error.

REAL_GIT="/usr/bin/git"

if [ -z "${EZGHA_GIT_MIRRORS:-}" ] || [ ! -d "${EZGHA_GIT_MIRRORS}" ]; then
  exec "$REAL_GIT" "$@"
fi

# Parse leading global git flags to find the subcommand and preserve any
# -C / --git-dir / --bare options for rev-parse / config / update-ref.
git_dir_args=()
subcommand=""
argc=$#
args=("$@")
idx=0

while [ "$idx" -lt "$argc" ]; do
  arg="${args[$idx]}"
  case "$arg" in
    -C|--git-dir)
      if [ $((idx + 1)) -ge "$argc" ]; then
        exec "$REAL_GIT" "$@"
      fi
      git_dir_args+=("$arg" "${args[$((idx + 1))]}")
      idx=$((idx + 2))
      ;;
    -C?*|--git-dir=*)
      git_dir_args+=("$arg")
      idx=$((idx + 1))
      ;;
    --bare)
      git_dir_args+=("$arg")
      idx=$((idx + 1))
      ;;
    --work-tree|-c|--namespace|--super-prefix|--exec-path|--config-env)
      if [ $((idx + 1)) -ge "$argc" ]; then
        exec "$REAL_GIT" "$@"
      fi
      idx=$((idx + 2))
      ;;
    --work-tree=*|-c?*|--namespace=*|--super-prefix=*|--exec-path=*|--config-env=*|--list-cmds=*)
      idx=$((idx + 1))
      ;;
    --no-pager|-p|--paginate|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-advice|--no-lazy-fetch)
      idx=$((idx + 1))
      ;;
    --)
      idx=$((idx + 1))
      if [ "$idx" -lt "$argc" ]; then
        subcommand="${args[$idx]}"
      fi
      break
      ;;
    -*)
      exec "$REAL_GIT" "$@"
      ;;
    *)
      subcommand="$arg"
      break
      ;;
  esac
done

if [ "$subcommand" != "fetch" ]; then
  exec "$REAL_GIT" "$@"
fi

# Inspect positional args after `fetch` so non-origin remotes pass straight through.
first_fetch_pos=""
fidx=$((idx + 1))
while [ "$fidx" -lt "$argc" ]; do
  farg="${args[$fidx]}"
  case "$farg" in
    -j|--jobs|--depth|--deepen|--shallow-since|--shallow-exclude|--negotiation-tip|--upload-pack|-o|--server-option|--refmap|--recurse-submodules-default|--submodule-prefix|--filter)
      if [ $((fidx + 1)) -ge "$argc" ]; then
        exec "$REAL_GIT" "$@"
      fi
      fidx=$((fidx + 2))
      ;;
    --)
      fidx=$((fidx + 1))
      if [ "$fidx" -lt "$argc" ]; then
        first_fetch_pos="${args[$fidx]}"
      fi
      break
      ;;
    -*)
      fidx=$((fidx + 1))
      ;;
    *)
      first_fetch_pos="$farg"
      break
      ;;
  esac
done

GIT_DIR="$("$REAL_GIT" "${git_dir_args[@]}" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ] || [ ! -d "$GIT_DIR" ]; then
  exec "$REAL_GIT" "$@"
fi
COMMON_DIR="$("$REAL_GIT" "${git_dir_args[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -z "$COMMON_DIR" ] || [ ! -d "$COMMON_DIR" ]; then
  COMMON_DIR="$GIT_DIR"
fi

ORIGIN_URL="$("$REAL_GIT" "${git_dir_args[@]}" config --get remote.origin.url 2>/dev/null || true)"
if [ -n "$first_fetch_pos" ] && [ "$first_fetch_pos" != "origin" ] && [ "$first_fetch_pos" != "$ORIGIN_URL" ]; then
  exec "$REAL_GIT" "$@"
fi
if [[ ! "$ORIGIN_URL" =~ ^https://([^/@]+@)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(\.git)?/?$ ]]; then
  exec "$REAL_GIT" "$@"
fi

OWNER="${BASH_REMATCH[2]}"
REPO="${BASH_REMATCH[3]}"
REPO="${REPO%.git}"

if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ "$OWNER" = "." ] || [ "$OWNER" = ".." ] || [ "$REPO" = "." ] || [ "$REPO" = ".." ]; then
  exec "$REAL_GIT" "$@"
fi

read_seed_sha() {
  local dir="$1" cand=""
  if [ -f "$dir/SEED_SHA" ]; then
    IFS= read -r cand < "$dir/SEED_SHA" || true
  elif [ -f "$dir/MAIN_SHA" ]; then
    IFS= read -r cand < "$dir/MAIN_SHA" || true
  else
    return 1
  fi
  cand="${cand//[[:space:]]/}"
  if [[ "$cand" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$cand"
    return 0
  fi
  return 1
}

ACTIVE_LINK="$EZGHA_GIT_MIRRORS/active/${OWNER}__${REPO}"
ALT_FILE="$COMMON_DIR/objects/info/alternates"
SEED_REF="refs/ezgha-seed/pid-$$-${RANDOM:-0}-$(date +%s 2>/dev/null || echo 0)"
LOCK_FILE="$COMMON_DIR/ezgha-hydrate.lock"
HAS_FLOCK=0
if command -v flock >/dev/null 2>&1; then
  HAS_FLOCK=1
fi
LOCK_HELD=0

acquire_lock() {
  if [ "$HAS_FLOCK" -eq 1 ] && [ "$LOCK_HELD" -eq 0 ] && { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
    if flock -x 9 2>/dev/null; then
      LOCK_HELD=1
    else
      exec 9>&-
    fi
  fi
}

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    exec 9>&-
    LOCK_HELD=0
  fi
}

HYDRATED_NOW=0
ALT_ADDED=0
SEED_CREATED=0
SEED_SHA=""
PRE_REFS=""
ALT_ENTRY=""

acquire_lock
if [ -e "$GIT_DIR/ezgha-hydrated" ]; then
  if [ -f "$ALT_FILE" ]; then
    while IFS= read -r alt_line || [ -n "$alt_line" ]; do
      alt_line="${alt_line%$'\r'}"
      case "$alt_line" in
        "${EZGHA_GIT_MIRRORS%/}"/*/objects)
          alt_gen="${alt_line%/objects}"
          SEED_SHA="$(read_seed_sha "$alt_gen" || true)"
          if [ -n "$SEED_SHA" ]; then
            break
          fi
          ;;
      esac
    done < "$ALT_FILE"

    if [ -z "$SEED_SHA" ] && [ -e "$ACTIVE_LINK" ]; then
      REAL_GEN="$(cd "$ACTIVE_LINK" 2>/dev/null && pwd -P || true)"
      if [ -n "$REAL_GEN" ] && [ -d "$REAL_GEN/objects" ] && grep -Fxq -- "$REAL_GEN/objects" "$ALT_FILE" 2>/dev/null; then
        SEED_SHA="$(read_seed_sha "$ACTIVE_LINK" || true)"
      fi
    fi
  fi

  if [ -n "$SEED_SHA" ]; then
    if "$REAL_GIT" "${git_dir_args[@]}" update-ref "$SEED_REF" "$SEED_SHA" "" >/dev/null 2>&1; then
      SEED_CREATED=1
    fi
  fi
else
  if [ ! -e "$ACTIVE_LINK" ]; then
    release_lock
    exec "$REAL_GIT" "$@"
  fi
  REAL_GEN="$(cd "$ACTIVE_LINK" 2>/dev/null && pwd -P || true)"
  if [ -z "$REAL_GEN" ] || [ ! -d "$REAL_GEN/objects" ]; then
    release_lock
    exec "$REAL_GIT" "$@"
  fi
  SEED_SHA="$(read_seed_sha "$REAL_GEN" || true)"
  if [ -z "$SEED_SHA" ]; then
    release_lock
    exec "$REAL_GIT" "$@"
  fi

  ALT_ENTRY="$REAL_GEN/objects"
  if mkdir -p "$COMMON_DIR/objects/info" 2>/dev/null; then
    ALT_OK=0
    if [ -f "$ALT_FILE" ] && grep -Fxq -- "$ALT_ENTRY" "$ALT_FILE" 2>/dev/null; then
      ALT_OK=1
    elif printf '%s\n' "$ALT_ENTRY" >> "$ALT_FILE" 2>/dev/null; then
      ALT_OK=1
      ALT_ADDED=1
    fi
    if [ "$ALT_OK" = "1" ] && touch "$GIT_DIR/ezgha-hydrated" 2>/dev/null; then
      HYDRATED_NOW=1
      PRE_REFS="$("$REAL_GIT" "${git_dir_args[@]}" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null | grep -v '^refs/ezgha-seed/' || true)"
      if "$REAL_GIT" "${git_dir_args[@]}" update-ref "$SEED_REF" "$SEED_SHA" "" >/dev/null 2>&1; then
        SEED_CREATED=1
      fi
    fi
  fi
fi
release_lock

"$REAL_GIT" -c core.commitGraph=false "$@"
rc=$?

acquire_lock
if [ "$SEED_CREATED" -eq 1 ]; then
  "$REAL_GIT" "${git_dir_args[@]}" update-ref -d "$SEED_REF" "$SEED_SHA" >/dev/null 2>&1 || true
fi

if [ "$rc" -ne 0 ] && [ "$HYDRATED_NOW" -eq 1 ]; then
  ACTIVE_BORROWERS="$("$REAL_GIT" "${git_dir_args[@]}" for-each-ref --count=1 --format='%(refname)' refs/ezgha-seed 2>/dev/null || true)"
  POST_REFS="$("$REAL_GIT" "${git_dir_args[@]}" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null | grep -v '^refs/ezgha-seed/' || true)"
  if [ -z "$ACTIVE_BORROWERS" ] && [ "$POST_REFS" = "$PRE_REFS" ]; then
    rm -f "$GIT_DIR/ezgha-hydrated" >/dev/null 2>&1 || true
    if [ "$ALT_ADDED" -eq 1 ] && [ -f "$ALT_FILE" ]; then
      tmp_alt="${ALT_FILE}.ezgha-tmp.$$"
      grep -Fvx -- "$ALT_ENTRY" "$ALT_FILE" > "$tmp_alt" 2>/dev/null
      grep_rc=$?
      if [ "$grep_rc" -eq 0 ]; then
        if [ -s "$tmp_alt" ]; then
          mv -f "$tmp_alt" "$ALT_FILE" 2>/dev/null || rm -f "$tmp_alt" >/dev/null 2>&1 || true
        else
          rm -f "$tmp_alt" "$ALT_FILE" >/dev/null 2>&1 || true
        fi
      elif [ "$grep_rc" -eq 1 ]; then
        rm -f "$tmp_alt" "$ALT_FILE" >/dev/null 2>&1 || true
      else
        rm -f "$tmp_alt" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi
release_lock

exit "$rc"
