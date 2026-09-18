#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_REMOTE=origin
readonly BUILD_SUFFIX_PATTERN='^([0-9]{12}(-[0-9]+-[0-9]+)?|[0-9]{14})$'

usage() {
  cat <<'EOF'
Usage:
  cleanup.sh same-label --snapshot-id SNAPSHOT_ID [--repository OWNER/REPO] [--remote REMOTE]
  cleanup.sh expired --max-age-days DAYS [--repository OWNER/REPO] [--remote REMOTE]

Modes:
  same-label  Delete prereleases and SPM branches for one exact snapshot id.
  expired     Delete expired prereleases, orphaned snapshot tags, and matching branches.

Required commands: git, gh, jq, date, awk, grep, mktemp, rm, tr
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
  for command in git gh jq date awk grep mktemp rm tr; do
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
  [[ "${tag#"$prefix"}" =~ $BUILD_SUFFIX_PATTERN ]] || return 1
  tag_timestamp "$tag" >/dev/null
}

matches_snapshot_id_branch() {
  local branch=$1
  local snapshot_id=$2
  local prefix="spm-ios-snapshot-${snapshot_id}-"

  [[ "$branch" == "$prefix"* ]] || return 1
  [[ "${branch#"$prefix"}" =~ $BUILD_SUFFIX_PATTERN ]] || return 1
  tag_timestamp "${branch#spm-}" >/dev/null
}

parse_iso_timestamp() {
  local value=$1

  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s 2>/dev/null \
    || date -u -d "$value" +%s 2>/dev/null
}

format_timestamp() {
  local value=$1

  date -u -r "$value" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$value" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
}

tag_timestamp() {
  local tag=$1
  local stamp
  local normalized
  local timestamp

  if [[ "$tag" =~ -([0-9]{14})$ ]]; then
    stamp=${BASH_REMATCH[1]}
    normalized="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:8:2}:${stamp:10:2}:${stamp:12:2}Z"
  elif [[ "$tag" =~ -([0-9]{12})(-[0-9]+-[0-9]+)?$ ]]; then
    stamp=${BASH_REMATCH[1]}
    normalized="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:8:2}:${stamp:10:2}:00Z"
  else
    return 1
  fi

  timestamp=$(parse_iso_timestamp "$normalized") || return 1
  [[ "$(format_timestamp "$timestamp")" == "$normalized" ]] || return 1
  printf '%s\n' "$timestamp"
}

is_recognized_snapshot_tag() {
  [[ "$1" == "ios-snapshot" ]] || tag_timestamp "$1" >/dev/null
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

tag_ref_exists() {
  local tag=$1
  local snapshot_tags_file=$2

  grep -Fqx "$tag" "$snapshot_tags_file"
}

fetch_releases() {
  local repository=$1
  local output_file=$2
  local pages_file=$3

  gh api --method GET --paginate \
    -H "Accept: application/vnd.github+json" \
    "repos/${repository}/releases?per_page=100" > "$pages_file"
  jq -s '[.[][] | {
      tagName: .tag_name,
      isPrerelease: .prerelease,
      createdAt: .created_at
    }]' "$pages_file" > "$output_file"
}

resolve_repository() {
  local repository=$1

  if [[ -n "$repository" ]]; then
    printf '%s\n' "$repository"
  elif [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s\n' "$GITHUB_REPOSITORY"
  else
    gh repo view --json nameWithOwner --jq '.nameWithOwner'
  fi
}

cleanup_temp_dir() {
  local path=$1

  [[ -n "$path" && -d "$path" ]] || return 0
  rm -rf -- "$path"
}

normalize_github_remote_url() {
  local url
  local path

  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$url" in
    https://github.com/*)
      path=${url#https://github.com/}
      ;;
    git@github.com:*)
      path=${url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      path=${url#ssh://git@github.com/}
      ;;
    *)
      return 1
      ;;
  esac

  path=${path%/}
  path=${path%.git}
  [[ "$path" == */* && "$path" != */*/* ]] || return 1
  printf '%s\n' "$path"
}

validate_repository_remote() {
  local repository=$1
  local remote=$2
  local remote_urls
  local remote_url
  local remote_repository
  local normalized_repository

  normalized_repository=$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')

  remote_urls=$(git remote get-url --all "$remote") \
    || fail "unable to resolve Git remote fetch URLs: $remote"
  [[ -n "$remote_urls" ]] || fail "Git remote has no fetch URL: $remote"
  while IFS= read -r remote_url; do
    remote_repository=$(normalize_github_remote_url "$remote_url") \
      || fail "unsupported or invalid GitHub remote URL: $remote_url"
    [[ "$remote_repository" == "$normalized_repository" ]] \
      || fail "repository mismatch: --repository is $repository but $remote fetches from $remote_repository"
  done <<< "$remote_urls"

  remote_urls=$(git remote get-url --push --all "$remote") \
    || fail "unable to resolve Git remote push URLs: $remote"
  [[ -n "$remote_urls" ]] || fail "Git remote has no push URL: $remote"
  while IFS= read -r remote_url; do
    remote_repository=$(normalize_github_remote_url "$remote_url") \
      || fail "unsupported or invalid GitHub push URL: $remote_url"
    [[ "$remote_repository" == "$normalized_repository" ]] \
      || fail "repository mismatch: --repository is $repository but $remote pushes to $remote_repository"
  done <<< "$remote_urls"
}

delete_matching_branch() {
  local tag=$1
  local remote=$2
  local branch="spm-${tag}"
  local status

  set +e
  git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null
  status=$?
  set -e
  case "$status" in
    0)
      echo "Deleting matching branch: $branch"
      git push "$remote" --delete "$branch" \
        || fail "unable to delete matching branch: $branch"
      ;;
    2)
      ;;
    *)
      fail "unable to check matching branch: $branch"
      ;;
  esac
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
  local repository=$3
  local temp_dir=$4
  local tag
  local branch

  fetch_releases "$repository" "$temp_dir/releases.json" "$temp_dir/release-pages.json"
  git ls-remote --tags "$remote" "refs/tags/ios-snapshot*" \
    | awk '$2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2 }' \
    | awk '$0 == "ios-snapshot" || /^ios-snapshot-/' > "$temp_dir/snapshot-tags"
  git ls-remote --heads "$remote" \
    | awk '{ sub("refs/heads/", "", $2); print $2 }' > "$temp_dir/branches"

  jq -r '.[] | select(.isPrerelease) | .tagName' \
    "$temp_dir/releases.json" > "$temp_dir/prerelease-tags"
  jq -r '.[].tagName' "$temp_dir/releases.json" > "$temp_dir/release-tags"

  while IFS= read -r tag; do
    if matches_snapshot_id_tag "$tag" "$snapshot_id"; then
      echo "Deleting previous snapshot release/tag: $tag"
      delete_matching_branch "$tag" "$remote"
      gh release delete "$tag" --repo "$repository" --yes --cleanup-tag \
        || fail "unable to delete previous snapshot release/tag: $tag"
    fi
  done < "$temp_dir/prerelease-tags"

  while IFS= read -r tag; do
    if matches_snapshot_id_tag "$tag" "$snapshot_id" \
      && ! release_exists "$tag" "$temp_dir/release-tags"; then
      echo "Deleting previous orphan snapshot tag: $tag"
      delete_matching_branch "$tag" "$remote"
      git push "$remote" --delete "refs/tags/$tag" \
        || fail "unable to delete previous orphan snapshot tag: $tag"
    fi
  done < "$temp_dir/snapshot-tags"

  while IFS= read -r branch; do
    tag=${branch#spm-}
    if matches_snapshot_id_branch "$branch" "$snapshot_id" \
      && ! release_exists "$tag" "$temp_dir/release-tags" \
      && ! tag_ref_exists "$tag" "$temp_dir/snapshot-tags"; then
      echo "Deleting previous snapshot branch: $branch"
      git push "$remote" --delete "$branch" \
        || fail "unable to delete previous snapshot branch: $branch"
    fi
  done < "$temp_dir/branches"
}

cleanup_expired() {
  local max_age_days=$1
  local remote=$2
  local repository=$3
  local temp_dir=$4
  local cutoff
  local tag
  local created_at
  local created_timestamp
  local age_source

  cutoff=$(cutoff_timestamp "$max_age_days") \
    || fail "unable to compute cutoff date with the installed date command"

  fetch_releases "$repository" "$temp_dir/releases.json" "$temp_dir/release-pages.json"
  jq -r '.[] | select(
      .isPrerelease
      and (.tagName == "ios-snapshot" or (.tagName | startswith("ios-snapshot-")))
    ) | [.tagName, .createdAt] | @tsv' \
    "$temp_dir/releases.json" > "$temp_dir/prereleases"
  jq -r '.[].tagName' "$temp_dir/releases.json" > "$temp_dir/release-tags"

  while IFS=$'\t' read -r tag created_at; do
    if ! is_recognized_snapshot_tag "$tag"; then
      echo "::warning::Preserving unrecognized snapshot prerelease: $tag" >&2
      continue
    fi
    created_timestamp=$(parse_iso_timestamp "$created_at") \
      || fail "unable to parse release creation date for $tag: $created_at"
    if is_strictly_older "$created_timestamp" "$cutoff"; then
      echo "Deleting expired release/tag: $tag (created $created_at)"
      delete_matching_branch "$tag" "$remote"
      gh release delete "$tag" --repo "$repository" --yes --cleanup-tag \
        || fail "unable to delete expired release/tag: $tag"
    fi
  done < "$temp_dir/prereleases"

  git ls-remote --tags "$remote" "refs/tags/ios-snapshot*" \
    | awk '$2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2 }' \
    | awk '$0 == "ios-snapshot" || /^ios-snapshot-/' > "$temp_dir/snapshot-tags"

  while IFS= read -r tag; do
    if release_exists "$tag" "$temp_dir/release-tags"; then
      continue
    fi

    if [[ "$tag" == "ios-snapshot" ]]; then
      created_timestamp=$(ref_timestamp "$tag" "$remote") \
        || fail "unable to determine target commit date for legacy orphan tag: $tag"
      age_source="tag target commit date"
    elif created_timestamp=$(tag_timestamp "$tag"); then
      age_source="timestamp encoded in tag"
    else
      echo "::warning::Preserving unrecognized orphan snapshot tag: $tag" >&2
      continue
    fi

    if is_strictly_older "$created_timestamp" "$cutoff"; then
      echo "Deleting expired orphan tag: $tag ($age_source)"
      delete_matching_branch "$tag" "$remote"
      git push "$remote" --delete "refs/tags/$tag" \
        || fail "unable to delete expired orphan tag: $tag"
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
  local repository=${GITHUB_REPOSITORY:-}
  local temp_dir
  local cleanup_command
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
      --repository)
        [[ $# -ge 2 ]] || fail "missing value for --repository"
        repository=$2
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
  repository=$(resolve_repository "$repository") \
    || fail "unable to determine repository; pass --repository OWNER/REPO"
  [[ "$repository" == */* && "$repository" != */*/* ]] \
    || fail "--repository must use OWNER/REPO format"
  validate_repository_remote "$repository" "$remote"

  temp_dir=$(mktemp -d)
  [[ -n "$temp_dir" && -d "$temp_dir" ]] || fail "mktemp did not create a temporary directory"
  printf -v cleanup_command 'cleanup_temp_dir %q' "$temp_dir"
  # shellcheck disable=SC2064 # Capture the validated temporary path before local variables leave scope.
  trap "$cleanup_command" EXIT

  case "$mode" in
    same-label)
      cleanup_same_label "$snapshot_id" "$remote" "$repository" "$temp_dir"
      ;;
    expired)
      cleanup_expired "$max_age_days" "$remote" "$repository" "$temp_dir"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
