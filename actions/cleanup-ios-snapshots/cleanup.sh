#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_REMOTE=origin
readonly BUILD_SUFFIX_PATTERN='^([0-9]{12}(-[0-9]+-[0-9]+)?|[0-9]{14})$'

usage() {
  cat <<'EOF'
Usage:
  cleanup.sh same-label --snapshot-id SNAPSHOT_ID [--remote REMOTE]
  cleanup.sh expired --max-age-days DAYS [--remote REMOTE]

Modes:
  same-label  Delete prereleases and SPM branches for one exact snapshot id.
  expired     Delete expired prereleases, orphaned snapshot tags, and matching branches.

Required commands: git, gh, jq, date, awk, grep, mktemp
GH_TOKEN must grant contents: write access to the target repository.
EOF
}

fail() {
  echo "cleanup-ios-snapshots: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_dependencies() {
  local command
  for command in git gh jq date awk grep mktemp; do
    require_command "$command"
  done
}

is_snapshot_tag() {
  [[ "$1" == "ios-snapshot" || "$1" == ios-snapshot-* ]]
}

matches_snapshot_id_tag() {
  local tag=$1
  local snapshot_id=$2
  local prefix="ios-snapshot-${snapshot_id}-"

  [[ "$tag" == "$prefix"* ]] || return 1
  [[ "${tag#"$prefix"}" =~ $BUILD_SUFFIX_PATTERN ]]
}

matches_snapshot_id_branch() {
  local branch=$1
  local snapshot_id=$2
  local prefix="spm-ios-snapshot-${snapshot_id}-"

  [[ "$branch" == "$prefix"* ]] || return 1
  [[ "${branch#"$prefix"}" =~ $BUILD_SUFFIX_PATTERN ]]
}

parse_iso_timestamp() {
  local value=$1

  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s 2>/dev/null \
    || date -u -d "$value" +%s 2>/dev/null
}

tag_timestamp() {
  local tag=$1
  local stamp
  local normalized

  if [[ "$tag" =~ -([0-9]{14})$ ]]; then
    stamp=${BASH_REMATCH[1]}
    normalized="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:8:2}:${stamp:10:2}:${stamp:12:2}Z"
  elif [[ "$tag" =~ -([0-9]{12})(-[0-9]+-[0-9]+)?$ ]]; then
    stamp=${BASH_REMATCH[1]}
    normalized="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:8:2}:${stamp:10:2}:00Z"
  else
    return 1
  fi

  parse_iso_timestamp "$normalized"
}

cutoff_timestamp() {
  local max_age_days=$1

  date -u -v-"${max_age_days}"d +%s 2>/dev/null \
    || date -u -d "-${max_age_days} days" +%s 2>/dev/null
}

is_strictly_older() {
  [[ "$1" -lt "$2" ]]
}

release_exists() {
  local tag=$1
  local release_tags_file=$2

  grep -Fqx "$tag" "$release_tags_file"
}

delete_matching_branch() {
  local tag=$1
  local remote=$2
  local branch="spm-${tag}"

  if git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1; then
    echo "Deleting matching branch: $branch"
    git push "$remote" --delete "$branch"
  fi
}

ref_timestamp() {
  local tag=$1
  local remote=$2

  git fetch --quiet --no-tags "$remote" "refs/tags/$tag"
  git log -1 --format=%ct FETCH_HEAD
}

cleanup_same_label() {
  local snapshot_id=$1
  local remote=$2
  local temp_dir=$3
  local tag
  local branch

  gh release list --json tagName,isPrerelease --limit 1000 > "$temp_dir/releases.json"
  jq -r '.[] | select(.isPrerelease) | .tagName' \
    "$temp_dir/releases.json" > "$temp_dir/prerelease-tags"

  while IFS= read -r tag; do
    if matches_snapshot_id_tag "$tag" "$snapshot_id"; then
      echo "Deleting previous snapshot release/tag: $tag"
      gh release delete "$tag" --yes --cleanup-tag
    fi
  done < "$temp_dir/prerelease-tags"

  git ls-remote --heads "$remote" \
    | awk '{ sub("refs/heads/", "", $2); print $2 }' > "$temp_dir/branches"

  while IFS= read -r branch; do
    if matches_snapshot_id_branch "$branch" "$snapshot_id"; then
      echo "Deleting previous snapshot branch: $branch"
      git push "$remote" --delete "$branch"
    fi
  done < "$temp_dir/branches"
}

cleanup_expired() {
  local max_age_days=$1
  local remote=$2
  local temp_dir=$3
  local cutoff
  local tag
  local created_at
  local created_timestamp
  local age_source

  cutoff=$(cutoff_timestamp "$max_age_days") \
    || fail "unable to compute cutoff date with the installed date command"

  gh release list --json tagName,isPrerelease,createdAt --limit 1000 > "$temp_dir/releases.json"
  jq -r '.[] | select(
      .isPrerelease
      and (.tagName == "ios-snapshot" or (.tagName | startswith("ios-snapshot-")))
    ) | [.tagName, .createdAt] | @tsv' \
    "$temp_dir/releases.json" > "$temp_dir/prereleases"
  jq -r '.[].tagName' "$temp_dir/releases.json" > "$temp_dir/release-tags"

  while IFS=$'\t' read -r tag created_at; do
    created_timestamp=$(parse_iso_timestamp "$created_at") \
      || fail "unable to parse release creation date for $tag: $created_at"
    if is_strictly_older "$created_timestamp" "$cutoff"; then
      echo "Deleting expired release/tag: $tag (created $created_at)"
      gh release delete "$tag" --yes --cleanup-tag
      delete_matching_branch "$tag" "$remote"
    fi
  done < "$temp_dir/prereleases"

  git ls-remote --tags "$remote" "refs/tags/ios-snapshot*" \
    | awk '$2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2 }' \
    | awk '$0 == "ios-snapshot" || /^ios-snapshot-/' > "$temp_dir/snapshot-tags"

  while IFS= read -r tag; do
    if release_exists "$tag" "$temp_dir/release-tags"; then
      continue
    fi

    if created_timestamp=$(tag_timestamp "$tag"); then
      age_source="timestamp encoded in tag"
    else
      created_timestamp=$(ref_timestamp "$tag" "$remote") \
        || fail "unable to determine target commit date for orphan tag: $tag"
      age_source="tag target commit date"
    fi

    if is_strictly_older "$created_timestamp" "$cutoff"; then
      echo "Deleting expired orphan tag: $tag ($age_source)"
      git push "$remote" --delete "refs/tags/$tag"
      delete_matching_branch "$tag" "$remote"
    fi
  done < "$temp_dir/snapshot-tags"
}

main() {
  [[ $# -gt 0 ]] || {
    usage >&2
    exit 2
  }
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
  fi

  local mode=$1
  local snapshot_id=
  local max_age_days=
  local remote=$DEFAULT_REMOTE
  local temp_dir
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot-id)
        [[ $# -ge 2 ]] || fail "missing value for --snapshot-id"
        snapshot_id=$2
        shift 2
        ;;
      --max-age-days)
        [[ $# -ge 2 ]] || fail "missing value for --max-age-days"
        max_age_days=$2
        shift 2
        ;;
      --remote)
        [[ $# -ge 2 ]] || fail "missing value for --remote"
        remote=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$remote" ]] || fail "--remote cannot be empty"
  case "$mode" in
    same-label)
      [[ -n "$snapshot_id" ]] || fail "same-label mode requires --snapshot-id"
      [[ -z "$max_age_days" ]] || fail "--max-age-days is only valid in expired mode"
      ;;
    expired)
      [[ -z "$snapshot_id" ]] || fail "--snapshot-id is only valid in same-label mode"
      [[ "$max_age_days" =~ ^[0-9]+$ ]] || fail "expired mode requires a non-negative integer --max-age-days"
      ;;
    *)
      usage >&2
      fail "unknown mode: $mode"
      ;;
  esac

  require_dependencies
  [[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN must be set"

  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' EXIT

  case "$mode" in
    same-label)
      cleanup_same_label "$snapshot_id" "$remote" "$temp_dir"
      ;;
    expired)
      cleanup_expired "$max_age_days" "$remote" "$temp_dir"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
