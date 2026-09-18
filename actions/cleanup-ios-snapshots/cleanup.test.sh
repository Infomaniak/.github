#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cleanup.sh"

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_true() {
  local description=$1
  shift
  "$@" || fail_test "$description"
}

assert_false() {
  local description=$1
  shift
  if "$@"; then
    fail_test "$description"
  fi
}

assert_equal() {
  local expected=$1
  local actual=$2
  local description=$3
  [[ "$actual" == "$expected" ]] \
    || fail_test "$description (expected '$expected', got '$actual')"
}

snapshot_id='1.2.3-jamy'
assert_true "current run-id tag matches exact snapshot id" \
  matches_snapshot_id_tag "ios-snapshot-$snapshot_id-202609011230-123-1" "$snapshot_id"
assert_true "legacy 12-digit tag matches exact snapshot id" \
  matches_snapshot_id_tag "ios-snapshot-$snapshot_id-202609011230" "$snapshot_id"
assert_true "legacy 14-digit tag matches exact snapshot id" \
  matches_snapshot_id_tag "ios-snapshot-$snapshot_id-20260901123045" "$snapshot_id"
assert_false "longer label must not overlap" \
  matches_snapshot_id_tag "ios-snapshot-$snapshot_id-extra-202609011230-123-1" "$snapshot_id"
assert_false "different label must not match" \
  matches_snapshot_id_tag "ios-snapshot-1.2.3-other-202609011230-123-1" "$snapshot_id"
assert_true "matching SPM branch is recognized" \
  matches_snapshot_id_branch "spm-ios-snapshot-$snapshot_id-202609011230-123-1" "$snapshot_id"
assert_false "different SPM branch label is preserved" \
  matches_snapshot_id_branch "spm-ios-snapshot-1.2.3-other-202609011230-123-1" "$snapshot_id"

assert_true "exact historical snapshot tag is recognized" is_snapshot_tag "ios-snapshot"
assert_true "versioned snapshot tag is recognized" is_snapshot_tag "ios-snapshot-1.2.3-202609011230"
assert_false "semver tag is excluded" is_snapshot_tag "v2.8.2"
assert_false "similar non-snapshot tag is excluded" is_snapshot_tag "ios-snapshots-1.2.3"

timestamp_12=$(tag_timestamp "ios-snapshot-1.2.3-202609011230")
timestamp_current=$(tag_timestamp "ios-snapshot-1.2.3-202609011230-123-1")
timestamp_14=$(tag_timestamp "ios-snapshot-1.2.3-20260901123045")
assert_equal "$timestamp_12" "$timestamp_current" "current tag uses its 12-digit timestamp"
assert_equal "$((timestamp_12 + 45))" "$timestamp_14" "legacy 14-digit timestamp includes seconds"
assert_false "timestamp-less historical tag uses commit fallback" tag_timestamp "ios-snapshot"

cutoff=$(parse_iso_timestamp "2026-09-03T12:00:00Z")
old=$(parse_iso_timestamp "2026-09-03T11:59:59Z")
recent=$(parse_iso_timestamp "2026-09-03T12:00:01Z")
assert_true "older timestamp is expired" is_strictly_older "$old" "$cutoff"
assert_false "exact 15-day cutoff is preserved" is_strictly_older "$cutoff" "$cutoff"
assert_false "recent snapshot is preserved" is_strictly_older "$recent" "$cutoff"

release_tags=$(mktemp)
trap 'rm -f "$release_tags"' EXIT
printf '%s\n' "ios-snapshot-1.2.3-202609011230" > "$release_tags"
assert_true "tag with a release is not orphaned" \
  release_exists "ios-snapshot-1.2.3-202609011230" "$release_tags"
assert_false "tag without a release is orphaned" \
  release_exists "ios-snapshot-1.2.3-20260901123045" "$release_tags"

test_dir=$(mktemp -d)
trap 'rm -f "$release_tags"; rm -rf "$test_dir"' EXIT
mock_releases=$test_dir/mock-releases.json
mock_heads=$test_dir/mock-heads
mock_tags=$test_dir/mock-tags
mock_calls=$test_dir/calls

gh() {
  if [[ "$1" == "release" && "$2" == "list" ]]; then
    cat "$mock_releases"
  elif [[ "$1" == "release" && "$2" == "delete" ]]; then
    printf 'release-delete %s\n' "$3" >> "$mock_calls"
  else
    fail_test "unexpected gh call: $*"
  fi
}

git() {
  if [[ "$1" == "ls-remote" && "$2" == "--heads" ]]; then
    cat "$mock_heads"
  elif [[ "$1" == "ls-remote" && "$2" == "--tags" ]]; then
    cat "$mock_tags"
  elif [[ "$1" == "ls-remote" && "$2" == "--exit-code" && "$3" == "--heads" ]]; then
    return 0
  elif [[ "$1" == "push" ]]; then
    printf 'git-push %s\n' "${*:2}" >> "$mock_calls"
  else
    fail_test "unexpected git call: $*"
  fi
}

cat > "$mock_releases" <<'EOF'
[
  {"tagName":"ios-snapshot-1.2.3-jamy-202609011230-123-1","isPrerelease":true},
  {"tagName":"ios-snapshot-1.2.3-jamy-202609011230","isPrerelease":true},
  {"tagName":"ios-snapshot-1.2.3-jamy-20260901123045","isPrerelease":true},
  {"tagName":"ios-snapshot-1.2.3-jamy-extra-202609011230-123-1","isPrerelease":true},
  {"tagName":"ios-snapshot-1.2.3-other-202609011230-123-1","isPrerelease":true}
]
EOF
cat > "$mock_heads" <<'EOF'
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-202609011230-123-1
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-202609011230
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-20260901123045
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-extra-202609011230-123-1
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-other-202609011230-123-1
EOF
: > "$mock_calls"
cleanup_same_label "$snapshot_id" origin "$test_dir"
assert_equal "6" "$(wc -l < "$mock_calls" | tr -d ' ')" \
  "same-label deletes three releases and three branches"
assert_false "same-label preserves longer labels" \
  grep -Fq "jamy-extra" "$mock_calls"
assert_false "same-label preserves different labels" \
  grep -Fq "other" "$mock_calls"

cutoff_timestamp() {
  parse_iso_timestamp "2026-09-03T12:00:00Z"
}

ref_timestamp() {
  [[ "$1" == "ios-snapshot" ]] || fail_test "unexpected commit-date fallback for $1"
  parse_iso_timestamp "2026-09-01T12:00:00Z"
}

cat > "$mock_releases" <<'EOF'
[
  {"tagName":"ios-snapshot-1.0-202609011200-123-1","isPrerelease":true,"createdAt":"2026-09-01T12:00:00Z"},
  {"tagName":"ios-snapshot-1.0-202609031200","isPrerelease":true,"createdAt":"2026-09-03T12:00:00Z"},
  {"tagName":"ios-snapshot-1.0-202608011200","isPrerelease":false,"createdAt":"2026-08-01T12:00:00Z"},
  {"tagName":"v2.8.2","isPrerelease":false,"createdAt":"2026-09-01T12:00:00Z"}
]
EOF
cat > "$mock_tags" <<'EOF'
deadbeef	refs/tags/ios-snapshot-1.0-202609011200-123-1
deadbeef	refs/tags/ios-snapshot-1.0-202609031200
deadbeef	refs/tags/ios-snapshot-1.0-202608011200
deadbeef	refs/tags/ios-snapshot-1.0-20260901120030
deadbeef	refs/tags/ios-snapshot-1.0-202609101200-456-1
deadbeef	refs/tags/ios-snapshot
deadbeef	refs/tags/v2.8.2
EOF
: > "$mock_calls"
cleanup_expired 15 origin "$test_dir"
assert_true "expired prerelease is deleted" \
  grep -Fq "release-delete ios-snapshot-1.0-202609011200-123-1" "$mock_calls"
assert_false "release at exact cutoff is preserved" \
  grep -Fq "202609031200" "$mock_calls"
assert_false "tag with an existing release is not treated as orphaned" \
  grep -Fq "202608011200" "$mock_calls"
assert_true "orphaned legacy 14-digit tag is deleted" \
  grep -Fq "refs/tags/ios-snapshot-1.0-20260901120030" "$mock_calls"
assert_false "recent orphaned current-format tag is preserved" \
  grep -Fq "202609101200-456-1" "$mock_calls"
assert_true "historical exact tag uses commit date and is deleted" \
  grep -Fxq "git-push origin --delete refs/tags/ios-snapshot" "$mock_calls"
assert_false "semver release tag is preserved" \
  grep -Fq "v2.8.2" "$mock_calls"

assert_true "--help succeeds without GitHub credentials" "$SCRIPT_DIR/cleanup.sh" --help
if "$SCRIPT_DIR/cleanup.sh" expired --max-age-days invalid > /dev/null 2>&1; then
  fail_test "invalid max-age-days must fail"
fi

echo "All cleanup iOS snapshot tests passed"
