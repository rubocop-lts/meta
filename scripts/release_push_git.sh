#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$META_DIR/.." && pwd)}"
EXECUTE=false
QUIET=false

REPOS=(
  rubocop-lts-rspec
  standard-rubocop-lts
  rubocop-ruby1_8
  rubocop-ruby1_9
  rubocop-ruby2_0
  rubocop-ruby2_1
  rubocop-ruby2_2
  rubocop-ruby2_3
  rubocop-ruby2_4
  rubocop-ruby2_5
  rubocop-ruby2_6
  rubocop-ruby2_7
  rubocop-ruby3_0
  rubocop-ruby3_1
  rubocop-ruby3_2
)

RUBOCOP_LTS_BRANCHES=(
  main
  r1_8-even-v0
  r1_9-even-v2
  r2_0-even-v4
  r2_1-even-v6
  r2_2-even-v8
  r2_3-even-v10
  r2_4-even-v12
  r2_5-even-v14
  r2_6-even-v16
  r2_7-even-v18
  r3_0-even-v20
  r3_1-even-v22
  r3_2-even-v24
)

declare -i BLOCKERS=0
declare -i PUSHES=0

usage() {
  cat <<'USAGE'
Usage: release_push_git.sh [options]

Push local commits for the RuboCop-LTS release workspace.

The script is a dry run unless --execute is given.

Options:
  --execute     Run git push commands
  --quiet       Reduce non-essential output
  -h, --help    Show this help

Environment:
  WORKSPACE_DIR Defaults to parent directory of meta repo

Exit codes:
  0  No blockers found
  1  One or more blockers found
USAGE
}

log() {
  if [ "$QUIET" = false ]; then
    printf '%s\n' "$*"
  fi
}

blocker() {
  BLOCKERS+=1
  printf 'BLOCKER: %s\n' "$*"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --execute)
        EXECUTE=true
        ;;
      --quiet)
        QUIET=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

require_repo() {
  local repo="$1"
  if [ ! -d "$WORKSPACE_DIR/$repo/.git" ]; then
    blocker "$repo is missing or is not a git repo at $WORKSPACE_DIR/$repo"
    return 1
  fi
  return 0
}

push_ref_if_needed() {
  local repo="$1"
  local ref="$2"
  local label="$3"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local upstream counts behind ahead remote remote_branch

  if ! upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref "$ref@{upstream}" 2>/dev/null); then
    blocker "$label has no upstream tracking branch configured"
    return
  fi

  counts=$(git -C "$repo_dir" rev-list --left-right --count "$upstream...$ref")
  behind=${counts%%[[:space:]]*}
  ahead=${counts##*[[:space:]]}

  if [ "$behind" -ne 0 ]; then
    blocker "$label is behind upstream $upstream by $behind commit(s)"
    return
  fi

  if [ "$ahead" -eq 0 ]; then
    log "OK: $label is synced with $upstream"
    return
  fi

  remote=${upstream%%/*}
  remote_branch=${upstream#*/}

  PUSHES+=1
  if [ "$EXECUTE" = true ]; then
    printf 'PUSH: %s -> %s (%d commit(s))\n' "$label" "$upstream" "$ahead"
    git -C "$repo_dir" push "$remote" "$ref:$remote_branch"
  else
    printf 'DRY-RUN: git -C %s push %s %s:%s # %s, %d commit(s)\n' "$repo_dir" "$remote" "$ref" "$remote_branch" "$label" "$ahead"
  fi
}

push_current_repo() {
  local repo="$1"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local branch dirty

  log ""
  log "--- $repo ---"

  if ! require_repo "$repo"; then
    return
  fi

  dirty=$(git -C "$repo_dir" status --porcelain)
  if [ -n "$dirty" ]; then
    blocker "$repo has uncommitted changes"
    return
  fi

  branch=$(git -C "$repo_dir" branch --show-current)
  if [ "$branch" != "main" ]; then
    blocker "$repo is on branch '$branch' (expected main)"
    return
  fi

  push_ref_if_needed "$repo" "$branch" "$repo:$branch"
}

push_rubocop_lts_matrix() {
  local repo="rubocop-lts"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local branch dirty

  log ""
  log "--- rubocop-lts branch matrix ---"

  if ! require_repo "$repo"; then
    return
  fi

  dirty=$(git -C "$repo_dir" status --porcelain)
  if [ -n "$dirty" ]; then
    blocker "$repo has uncommitted changes"
    return
  fi

  for branch in "${RUBOCOP_LTS_BRANCHES[@]}"; do
    if ! git -C "$repo_dir" rev-parse --verify "$branch" >/dev/null 2>&1; then
      blocker "rubocop-lts missing local branch $branch"
      continue
    fi

    push_ref_if_needed "$repo" "$branch" "rubocop-lts:$branch"
  done
}

main() {
  parse_args "$@"

  printf 'Release git push %s\n' "$( [ "$EXECUTE" = true ] && echo started || echo dry-run )"
  printf 'Workspace: %s\n' "$WORKSPACE_DIR"

  push_rubocop_lts_matrix
  for repo in "${REPOS[@]}"; do
    push_current_repo "$repo"
  done

  printf '\n=== release git push summary ===\n'
  printf 'workspace: %s\n' "$WORKSPACE_DIR"
  printf 'mode:      %s\n' "$( [ "$EXECUTE" = true ] && echo execute || echo dry-run )"
  printf 'pushes:    %d\n' "$PUSHES"
  printf 'blockers:  %d\n' "$BLOCKERS"

  if [ "$BLOCKERS" -eq 0 ]; then
    printf 'RESULT: PASS\n'
  else
    printf 'RESULT: FAIL (fix blockers before pushing)\n'
  fi

  exit "$BLOCKERS"
}

main "$@"
