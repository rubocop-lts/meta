#!/usr/bin/env bash
set -euo pipefail

# release_gate.sh
# Audits the rubocop-lts family for release-readiness and can optionally run
# the validation suite that was used during modernization.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$META_DIR/.." && pwd)}"
TMPDIR="${TMPDIR:-$WORKSPACE_DIR/tmp}"
VALIDATION_LOG_DIR="$TMPDIR/release_gate"
RUN_VALIDATION=false
AUDIT_BUMPS=false
REQUIRE_TAGS=false
QUIET=false
BUMP_AUDIT_LOG=""

REPOS=(
  rubocop-lts
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

# branch -> expected wrapper dependency in rubocop-lts.gemspec
EXPECTED_WRAPPER=(
  "main:rubocop-ruby3_2"
  "r1_8-even-v0:rubocop-ruby1_8"
  "r1_9-even-v2:rubocop-ruby1_9"
  "r2_0-even-v4:rubocop-ruby2_0"
  "r2_1-even-v6:rubocop-ruby2_1"
  "r2_2-even-v8:rubocop-ruby2_2"
  "r2_3-even-v10:rubocop-ruby2_3"
  "r2_4-even-v12:rubocop-ruby2_4"
  "r2_5-even-v14:rubocop-ruby2_5"
  "r2_6-even-v16:rubocop-ruby2_6"
  "r2_7-even-v18:rubocop-ruby2_7"
  "r3_0-even-v20:rubocop-ruby3_0"
  "r3_1-even-v22:rubocop-ruby3_1"
  "r3_2-even-v24:rubocop-ruby3_2"
)

declare -i BLOCKERS=0
declare -i WARNINGS=0

usage() {
  cat <<'USAGE'
Usage: release_gate.sh [options]

Options:
  --run-validation   Run specs and rubocop_gradual checks (slow)
  --audit-bumps      Run semantic bump-policy audit (release_bump_plan.rb)
  --require-tags     Enforce version/tag alignment checks as post-release blockers
  --quiet            Reduce non-essential output
  -h, --help         Show this help

Environment overrides:
  WORKSPACE_DIR      Defaults to parent directory of meta repo
  TMPDIR             Defaults to $WORKSPACE_DIR/tmp

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

warn() {
  WARNINGS+=1
  printf 'WARNING: %s\n' "$*"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-validation)
        RUN_VALIDATION=true
        ;;
      --audit-bumps)
        AUDIT_BUMPS=true
        ;;
      --require-tags)
        REQUIRE_TAGS=true
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

repo_version() {
  local repo="$1"
  local version_file
  version_file=$(find "$WORKSPACE_DIR/$repo/lib" -path '*/version.rb' -type f | head -n 1 || true)
  if [ -z "$version_file" ]; then
    echo ""
    return
  fi
  grep -E 'VERSION *= *"' "$version_file" | head -n 1 | sed -E 's/.*VERSION *= *"([^"]+)".*/\1/'
}

audit_gemspec() {
  local repo="$1"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local gemspec

  gemspec=$(find "$repo_dir" -maxdepth 1 -name '*.gemspec' -type f | head -n 1 || true)
  if [ -z "$gemspec" ]; then
    warn "$repo has no gemspec"
    return
  fi

  if ! ruby -e 'Dir.chdir(ARGV.fetch(0)) { spec = Gem::Specification.load(ARGV.fetch(1)); spec.validate }' "$repo_dir" "$(basename "$gemspec")" >/dev/null 2>&1; then
    blocker "$repo gemspec is invalid ($gemspec)"
  fi
}

audit_gemfile_sources() {
  local repo="$1"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local gemfile="$repo_dir/Gemfile"

  if [ ! -f "$gemfile" ]; then
    return
  fi

  if grep -Eq '(^|[[:space:],])(:github[[:space:]]*=>|github:|git:)' "$gemfile"; then
    blocker "$repo Gemfile contains an active git dependency"
  fi
}

audit_rubocop_lts_branch_sources() {
  local repo_dir="$WORKSPACE_DIR/rubocop-lts"
  local branch file content

  for branch in "${RUBOCOP_LTS_BRANCHES[@]}"; do
    if ! git -C "$repo_dir" rev-parse --verify "$branch" >/dev/null 2>&1; then
      continue
    fi

    while IFS= read -r file; do
      content=$(git -C "$repo_dir" show "$branch:$file" 2>/dev/null || true)
      if grep -Eq '(^|[[:space:],])(:github[[:space:]]*=>|github:|git:)' <<<"$content"; then
        blocker "rubocop-lts:$branch $file contains an active git dependency"
      fi
    done < <(git -C "$repo_dir" ls-tree -r --name-only "$branch" -- Gemfile gemfiles '*.gemspec' | grep -E '(^Gemfile$|\.gemfile$|\.gemspec$)' || true)
  done
}

check_ref_sync() {
  local repo="$1"
  local ref="$2"
  local label="$3"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local upstream ahead behind

  if upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref "$ref@{upstream}" 2>/dev/null); then
    ahead=$(git -C "$repo_dir" rev-list --left-right --count "$upstream...$ref" | awk '{print $2}')
    behind=$(git -C "$repo_dir" rev-list --left-right --count "$upstream...$ref" | awk '{print $1}')
    if [ "$ahead" -ne 0 ] || [ "$behind" -ne 0 ]; then
      blocker "$label is not fully synced with upstream $upstream (ahead=$ahead behind=$behind)"
    fi
  else
    blocker "$label has no upstream tracking branch configured"
  fi
}

check_version_tag() {
  local repo="$1"
  local ref="$2"
  local label="$3"
  local version="$4"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local tag commits

  tag="v$version"
  if git -C "$repo_dir" rev-parse "$tag" >/dev/null 2>&1; then
    commits=$(git -C "$repo_dir" rev-list --count "$tag".."$ref")
    if [ "$commits" -ne 0 ]; then
      blocker "$label is $commits commit(s) past version tag $tag"
    else
      log "OK: $label version/tag aligned at $tag"
    fi
  else
    blocker "$label missing version tag $tag"
  fi
}

audit_repo_state() {
  local repo="$1"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local branch dirty version

  log ""
  log "--- $repo ---"

  if ! require_repo "$repo"; then
    return
  fi

  branch=$(git -C "$repo_dir" branch --show-current)
  if [ "$repo" != "rubocop-lts" ] && [ "$branch" != "main" ]; then
    blocker "$repo is on branch '$branch' (expected main)"
  fi

  dirty=$(git -C "$repo_dir" status --porcelain)
  if [ -n "$dirty" ]; then
    blocker "$repo has uncommitted changes"
  fi

  audit_gemspec "$repo"
  audit_gemfile_sources "$repo"

  if [ "$repo" != "rubocop-lts" ]; then
    check_ref_sync "$repo" "HEAD" "$repo:$branch"
  fi

  version=$(repo_version "$repo")
  if [ -z "$version" ]; then
    warn "$repo version could not be determined from lib/**/version.rb"
    return
  fi

  if [ "$REQUIRE_TAGS" = true ] && [ "$repo" != "rubocop-lts" ]; then
    check_version_tag "$repo" "HEAD" "$repo:$branch" "$version"
  fi
}

audit_rubocop_lts_branches() {
  local repo_dir="$WORKSPACE_DIR/rubocop-lts"
  local branch expected dep_line std_line rspec_line version

  if ! require_repo "rubocop-lts"; then
    return
  fi

  log ""
  log "=== rubocop-lts branch matrix audit ==="

  audit_rubocop_lts_branch_sources

  for pair in "${EXPECTED_WRAPPER[@]}"; do
    branch=${pair%%:*}
    expected=${pair#*:}

    if ! git -C "$repo_dir" rev-parse --verify "$branch" >/dev/null 2>&1; then
      blocker "rubocop-lts missing local branch $branch"
      continue
    fi

    check_ref_sync "rubocop-lts" "$branch" "rubocop-lts:$branch"

    dep_line=$(git -C "$repo_dir" show "$branch:rubocop-lts.gemspec" | grep 'spec.add_dependency("rubocop-ruby' || true)
    std_line=$(git -C "$repo_dir" show "$branch:rubocop-lts.gemspec" | grep -F 'spec.add_dependency("standard-rubocop-lts", ">= 2.0.2", "< 3")' || true)
    rspec_line=$(git -C "$repo_dir" show "$branch:rubocop-lts.gemspec" | grep 'spec.add_development_dependency("rubocop-lts-rspec", "~> 1.0", ">= 1.0.1")' || true)

    if [[ "$dep_line" != *"$expected"* ]]; then
      blocker "rubocop-lts:$branch wrapper mismatch (expected $expected)"
    fi
    if [ -z "$std_line" ]; then
      blocker "rubocop-lts:$branch does not pin standard-rubocop-lts >= 2.0.2, < 3"
    fi
    if [ -z "$rspec_line" ]; then
      blocker "rubocop-lts:$branch missing rubocop-lts-rspec ~> 1.0, >= 1.0.1 dev dependency"
    fi

    version=$(git -C "$repo_dir" show "$branch:lib/rubocop/lts/version.rb" | grep 'VERSION =' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ "$REQUIRE_TAGS" = true ]; then
      check_version_tag "rubocop-lts" "$branch" "rubocop-lts:$branch" "$version"
    fi
  done
}

run_validation_suite() {
  mkdir -p "$VALIDATION_LOG_DIR"

  log ""
  log "=== validation suite ==="

  run_cmd "rubocop-lts-rspec" "bundle exec rake spec"
  run_cmd "standard-rubocop-lts" "bundle exec rake spec"
  run_cmd "rubocop-lts" "RUBOCOP_LTS_DEV=true bundle exec rake spec"

  for repo in rubocop-ruby1_8 rubocop-ruby1_9 rubocop-ruby2_0 rubocop-ruby2_1 rubocop-ruby2_2 rubocop-ruby2_3 rubocop-ruby2_4 rubocop-ruby2_5 rubocop-ruby2_6 rubocop-ruby2_7 rubocop-ruby3_0 rubocop-ruby3_1 rubocop-ruby3_2 rubocop-lts; do
    run_cmd "$repo" "RUBOCOP_LTS_DEV=true bundle exec rake rubocop_gradual:check"
  done
}

run_cmd() {
  local repo="$1"
  local cmd="$2"
  local repo_dir="$WORKSPACE_DIR/$repo"
  local log_file="$VALIDATION_LOG_DIR/${repo//\//_}.log"

  if ! require_repo "$repo"; then
    return
  fi

  log "RUN: ($repo) $cmd"
  if (cd "$repo_dir" && eval "$cmd") >"$log_file" 2>&1; then
    log "OK: $repo"
  else
    blocker "validation failed in $repo (see $log_file)"
  fi
}

run_bump_audit() {
  local bump_script="$META_DIR/scripts/release_bump_plan.rb"
  local -a bump_args=()

  if [ ! -x "$bump_script" ]; then
    blocker "bump audit script is missing or not executable: $bump_script"
    return
  fi

  BUMP_AUDIT_LOG="$TMPDIR/release_bump_plan.log"
  if [ "$REQUIRE_TAGS" = true ]; then
    bump_args+=("--require-tags")
  fi
  log "RUN: bump audit ($bump_script)"

  if WORKSPACE_DIR="$WORKSPACE_DIR" TMPDIR="$TMPDIR" "$bump_script" "${bump_args[@]}" >"$BUMP_AUDIT_LOG" 2>&1; then
    log "OK: bump audit"
  else
    blocker "bump audit failed (see $BUMP_AUDIT_LOG)"
  fi
}

print_summary() {
  printf '\n=== release gate summary ===\n'
  printf 'workspace: %s\n' "$WORKSPACE_DIR"
  printf 'tmpdir:    %s\n' "$TMPDIR"
  printf 'warnings:  %d\n' "$WARNINGS"
  printf 'blockers:  %d\n' "$BLOCKERS"

  if [ "$RUN_VALIDATION" = true ]; then
    printf 'logs:      %s\n' "$VALIDATION_LOG_DIR"
  fi

  if [ "$AUDIT_BUMPS" = true ]; then
    printf 'bump log:  %s\n' "$BUMP_AUDIT_LOG"
  fi

  printf 'tags:      %s\n' "$( [ "$REQUIRE_TAGS" = true ] && echo required || echo unchecked )"

  if [ "$BLOCKERS" -eq 0 ]; then
    printf 'RESULT: PASS (release gate is green)\n'
  else
    printf 'RESULT: FAIL (fix blockers before release)\n'
  fi
}

main() {
  parse_args "$@"

  mkdir -p "$TMPDIR"
  export TMPDIR

  log "Release gate started"
  log "Workspace: $WORKSPACE_DIR"
  log "TMPDIR:    $TMPDIR"

  for repo in "${REPOS[@]}"; do
    audit_repo_state "$repo"
  done

  audit_rubocop_lts_branches

  if [ "$RUN_VALIDATION" = true ]; then
    run_validation_suite
  fi

  if [ "$AUDIT_BUMPS" = true ]; then
    run_bump_audit
  fi

  print_summary

  if [ "$BLOCKERS" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
