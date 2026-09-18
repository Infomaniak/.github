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
assert_false "invalid timestamp must not match same-label cleanup" \
  matches_snapshot_id_tag "ios-snapshot-$snapshot_id-202613011200-123-1" "$snapshot_id"
assert_true "matching SPM branch is recognized" \
  matches_snapshot_id_branch "spm-ios-snapshot-$snapshot_id-202609011230-123-1" "$snapshot_id"
assert_false "different SPM branch label is preserved" \
  matches_snapshot_id_branch "spm-ios-snapshot-1.2.3-other-202609011230-123-1" "$snapshot_id"
assert_true "existing format treats version-label ambiguity as the same snapshot id" \
  matches_snapshot_id_tag "ios-snapshot-1.2.3-feature-202609011230-123-1" "1.2.3-feature"

assert_equal "owner/repo" \
  "$(normalize_github_remote_url "https://GitHub.com/Owner/Repo.git")" \
  "HTTPS GitHub remotes are normalized"
assert_equal "owner/repo" \
  "$(normalize_github_remote_url "git@github.com:Owner/Repo.git")" \
  "SCP-style SSH GitHub remotes are normalized"
assert_equal "owner/repo" \
  "$(normalize_github_remote_url "ssh://git@github.com/Owner/Repo.git")" \
  "SSH URL GitHub remotes are normalized"
assert_false "non-GitHub remotes fail closed" \
  normalize_github_remote_url "https://gitlab.com/owner/repo.git"

assert_true "exact historical snapshot tag is recognized" is_snapshot_tag "ios-snapshot"
assert_true "versioned snapshot tag is recognized" is_snapshot_tag "ios-snapshot-1.2.3-202609011230"
assert_false "semver tag is excluded" is_snapshot_tag "v2.8.2"
assert_false "similar non-snapshot tag is excluded" is_snapshot_tag "ios-snapshots-1.2.3"

timestamp_12=$(tag_timestamp "ios-snapshot-1.2.3-202609011230")
timestamp_current=$(tag_timestamp "ios-snapshot-1.2.3-202609011230-123-1")
timestamp_14=$(tag_timestamp "ios-snapshot-1.2.3-20260901123045")
assert_equal "$timestamp_12" "$timestamp_current" "current tag uses its 12-digit timestamp"
assert_equal "$((timestamp_12 + 45))" "$timestamp_14" "legacy 14-digit timestamp includes seconds"
assert_true "free-form labels with a valid suffix remain supported" \
  tag_timestamp "ios-snapshot-caldav-interceptor-202608210904-32465573347-1"
assert_true "valid leap days are accepted" \
  tag_timestamp "ios-snapshot-leap-202402291200"
assert_false "invalid month is rejected" \
  tag_timestamp "ios-snapshot-invalid-202613011200"
assert_false "invalid day is rejected" \
  tag_timestamp "ios-snapshot-invalid-202602301200"
assert_false "invalid hour is rejected" \
  tag_timestamp "ios-snapshot-invalid-202601012400"
assert_false "invalid minute is rejected" \
  tag_timestamp "ios-snapshot-invalid-202601011260"
assert_false "invalid second is rejected" \
  tag_timestamp "ios-snapshot-invalid-20260101120060"
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
mock_release_pages=$test_dir/mock-release-pages.json
mock_heads=$test_dir/mock-heads
mock_tags=$test_dir/mock-tags
mock_calls=$test_dir/calls
mock_branch_status=0
mock_release_delete_status=0

gh() {
  if [[ "$1" == "api" ]]; then
    [[ " $* " == *" --paginate "* ]] || fail_test "release API call must paginate"
    [[ " $* " == *" repos/owner/repo/releases?per_page=100 "* ]] \
      || fail_test "release API call must target the requested repository"
    cat "$mock_release_pages"
  elif [[ "$1" == "release" && "$2" == "delete" ]]; then
    printf 'release-delete %s\n' "$3" >> "$mock_calls"
    return "$mock_release_delete_status"
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
    return "$mock_branch_status"
  elif [[ "$1" == "push" ]]; then
    printf 'git-push %s\n' "${*:2}" >> "$mock_calls"
  else
    fail_test "unexpected git call: $*"
  fi
}

cat > "$mock_release_pages" <<'EOF'
[
  {"tag_name":"ios-snapshot-1.2.3-jamy-202609011230-123-1","prerelease":true,"created_at":"2026-09-01T12:00:00Z"},
  {"tag_name":"ios-snapshot-1.2.3-jamy-202609011230","prerelease":true,"created_at":"2026-09-01T12:00:00Z"},
  {"tag_name":"ios-snapshot-1.2.3-jamy-extra-202609011230-123-1","prerelease":true,"created_at":"2026-09-01T12:00:00Z"}
]
[
  {"tag_name":"ios-snapshot-1.2.3-jamy-20260901123045","prerelease":true,"created_at":"2026-09-01T12:00:00Z"},
  {"tag_name":"ios-snapshot-1.2.3-other-202609011230-123-1","prerelease":true,"created_at":"2026-09-01T12:00:00Z"}
]
EOF
cat > "$mock_tags" <<'EOF'
deadbeef	refs/tags/ios-snapshot-1.2.3-jamy-202609011230-123-1
deadbeef	refs/tags/ios-snapshot-1.2.3-jamy-202609011230
deadbeef	refs/tags/ios-snapshot-1.2.3-jamy-20260901123045
EOF
cat > "$mock_heads" <<'EOF'
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-202609011230-123-1
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-202609011230
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-20260901123045
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-jamy-extra-202609011230-123-1
deadbeef	refs/heads/spm-ios-snapshot-1.2.3-other-202609011230-123-1
EOF
: > "$mock_calls"
cleanup_same_label "$snapshot_id" origin owner/repo "$test_dir"
assert_equal "6" "$(wc -l < "$mock_calls" | tr -d ' ')" \
  "same-label deletes three releases and three branches"
assert_false "same-label preserves longer labels" \
  grep -Fq "jamy-extra" "$mock_calls"
assert_false "same-label preserves different labels" \
  grep -Fq "other" "$mock_calls"
assert_true "same-label includes matching release from a later page" \
  grep -Fq "release-delete ios-snapshot-1.2.3-jamy-20260901123045" "$mock_calls"

cutoff_timestamp() {
  parse_iso_timestamp "2026-09-03T12:00:00Z"
}

ref_timestamp() {
  [[ "$1" == "ios-snapshot" ]] || fail_test "unexpected commit-date fallback for $1"
  parse_iso_timestamp "2026-09-01T12:00:00Z"
}

cat > "$mock_release_pages" <<'EOF'
[
  {"tag_name":"ios-snapshot-1.0-202609011200-123-1","prerelease":true,"created_at":"2026-09-01T12:00:00Z"},
  {"tag_name":"ios-snapshot-1.0-202609031200","prerelease":true,"created_at":"2026-09-03T12:00:00Z"},
  {"tag_name":"ios-snapshot-manual","prerelease":true,"created_at":"2020-01-01T00:00:00Z"}
]
[
  {"tag_name":"ios-snapshot-1.0-202608011200","prerelease":false,"created_at":"2026-08-01T12:00:00Z"},
  {"tag_name":"v2.8.2","prerelease":false,"created_at":"2026-09-01T12:00:00Z"}
]
EOF
cat > "$mock_tags" <<'EOF'
deadbeef	refs/tags/ios-snapshot-1.0-202609011200-123-1
deadbeef	refs/tags/ios-snapshot-1.0-202609031200
deadbeef	refs/tags/ios-snapshot-1.0-202608011200
deadbeef	refs/tags/ios-snapshot-1.0-20260901120030
deadbeef	refs/tags/ios-snapshot-1.0-202609101200-456-1
deadbeef	refs/tags/ios-snapshot-caldav-interceptor-202608210904-32465573347-1
deadbeef	refs/tags/ios-snapshot-manual-orphan
deadbeef	refs/tags/ios-snapshot-invalid-202613011200
deadbeef	refs/tags/ios-snapshot
deadbeef	refs/tags/v2.8.2
EOF
: > "$mock_calls"
warnings=$test_dir/warnings
cleanup_expired 15 origin owner/repo "$test_dir" 2> "$warnings"
assert_true "expired prerelease is deleted" \
  grep -Fq "release-delete ios-snapshot-1.0-202609011200-123-1" "$mock_calls"
assert_false "release at exact cutoff is preserved" \
  grep -Fq "202609031200" "$mock_calls"
assert_false "tag with an existing release is not treated as orphaned" \
  grep -Fq "202608011200" "$mock_calls"
assert_true "orphaned legacy 14-digit tag is deleted" \
  grep -Fq "refs/tags/ios-snapshot-1.0-20260901120030" "$mock_calls"
assert_true "free-form label with valid generated suffix is deleted" \
  grep -Fq "refs/tags/ios-snapshot-caldav-interceptor-202608210904-32465573347-1" "$mock_calls"
assert_false "recent orphaned current-format tag is preserved" \
  grep -Fq "202609101200-456-1" "$mock_calls"
assert_true "historical exact tag uses commit date and is deleted" \
  grep -Fxq "git-push origin --delete refs/tags/ios-snapshot" "$mock_calls"
assert_false "semver release tag is preserved" \
  grep -Fq "v2.8.2" "$mock_calls"
assert_false "manual orphan tag is preserved" \
  grep -Fq "refs/tags/ios-snapshot-manual-orphan" "$mock_calls"
assert_false "invalid timestamp orphan tag is preserved" \
  grep -Fq "refs/tags/ios-snapshot-invalid-202613011200" "$mock_calls"
assert_false "unrecognized old prerelease is preserved" \
  grep -Fq "release-delete ios-snapshot-manual" "$mock_calls"
assert_true "manual orphan preservation emits a warning" \
  grep -Fq "Preserving unrecognized orphan snapshot tag: ios-snapshot-manual-orphan" "$warnings"
assert_true "invalid timestamp preservation emits a warning" \
  grep -Fq "Preserving unrecognized orphan snapshot tag: ios-snapshot-invalid-202613011200" "$warnings"
assert_true "unrecognized prerelease preservation emits a warning" \
  grep -Fq "Preserving unrecognized snapshot prerelease: ios-snapshot-manual" "$warnings"

: > "$mock_calls"
mock_release_delete_status=1
if (cleanup_expired 15 origin owner/repo "$test_dir" 2> /dev/null); then
  fail_test "release deletion failure must abort"
fi
assert_equal "git-push origin --delete spm-ios-snapshot-1.0-202609011200-123-1" \
  "$(sed -n '1p' "$mock_calls")" \
  "matching branch is deleted before its release"
assert_equal "release-delete ios-snapshot-1.0-202609011200-123-1" \
  "$(sed -n '2p' "$mock_calls")" \
  "failed release remains the retry anchor"

: > "$mock_calls"
mock_branch_status=2
mock_release_delete_status=0
cleanup_expired 15 origin owner/repo "$test_dir" 2> /dev/null
assert_true "rerun completes release deletion after partial failure" \
  grep -Fq "release-delete ios-snapshot-1.0-202609011200-123-1" "$mock_calls"

: > "$mock_calls"
mock_branch_status=2
delete_matching_branch "ios-snapshot-absent-202609011200" origin
assert_equal "0" "$(wc -l < "$mock_calls" | tr -d ' ')" \
  "missing matching branch is idempotently ignored"

: > "$mock_calls"
mock_branch_status=128
if (delete_matching_branch "ios-snapshot-error-202609011200" origin); then
  fail_test "operational branch lookup failure must abort"
fi
assert_equal "0" "$(wc -l < "$mock_calls" | tr -d ' ')" \
  "branch lookup failure must not mutate"
mock_branch_status=0

assert_true "--help succeeds without GitHub credentials" "$SCRIPT_DIR/cleanup.sh" --help
if "$SCRIPT_DIR/cleanup.sh" expired --max-age-days invalid > /dev/null 2>&1; then
  fail_test "invalid max-age-days must fail"
fi

mock_bin=$test_dir/bin
trapped_temp_dir=$test_dir/trapped-temp
mkdir -p "$mock_bin"
cat > "$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
touch "$GH_CALLED"
if [[ "$1" == "api" ]]; then
  printf '[]\n'
else
  exit 1
fi
EOF
cat > "$mock_bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "remote" && "$2" == "get-url" && "$3" == "--push" ]]; then
  printf '%s\n' "$MOCK_PUSH_URL"
elif [[ "$1" == "remote" && "$2" == "get-url" ]]; then
  printf '%s\n' "$MOCK_REMOTE_URL"
elif [[ "$1" == "ls-remote" ]]; then
  exit 0
else
  exit 1
fi
EOF
cat > "$mock_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$MOCK_TEMP_DIR"
printf '%s\n' "$MOCK_TEMP_DIR"
EOF
chmod +x "$mock_bin/gh" "$mock_bin/git" "$mock_bin/mktemp"
gh_called=$test_dir/gh-called
PATH="$mock_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=owner/repo \
  MOCK_TEMP_DIR="$trapped_temp_dir" GH_CALLED="$gh_called" \
  MOCK_REMOTE_URL="git@github.com:Owner/Repo.git" \
  MOCK_PUSH_URL="ssh://git@github.com/Owner/Repo.git" \
  "$SCRIPT_DIR/cleanup.sh" same-label --snapshot-id no-match
[[ ! -e "$trapped_temp_dir" ]] \
  || fail_test "successful CLI execution must remove its temporary directory"
[[ -e "$gh_called" ]] || fail_test "successful validated execution must reach the GitHub API"

rm -f "$gh_called"
if PATH="$mock_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=owner/repo \
  MOCK_TEMP_DIR="$trapped_temp_dir" GH_CALLED="$gh_called" \
  MOCK_REMOTE_URL="https://github.com/other/repo.git" \
  MOCK_PUSH_URL="https://github.com/owner/repo.git" \
  "$SCRIPT_DIR/cleanup.sh" same-label --snapshot-id no-match > /dev/null 2>&1; then
  fail_test "repository/remote mismatch must fail"
fi
[[ ! -e "$gh_called" ]] || fail_test "repository mismatch must fail before GitHub API access"
[[ ! -e "$trapped_temp_dir" ]] || fail_test "repository mismatch must fail before creating temp state"

if PATH="$mock_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=owner/repo \
  MOCK_TEMP_DIR="$trapped_temp_dir" GH_CALLED="$gh_called" \
  MOCK_REMOTE_URL="https://github.com/owner/repo.git" \
  MOCK_PUSH_URL="git@github.com:other/repo.git" \
  "$SCRIPT_DIR/cleanup.sh" same-label --snapshot-id no-match > /dev/null 2>&1; then
  fail_test "repository/push URL mismatch must fail"
fi
[[ ! -e "$gh_called" ]] || fail_test "push URL mismatch must fail before GitHub API access"
[[ ! -e "$trapped_temp_dir" ]] || fail_test "push URL mismatch must fail before creating temp state"

repo_root=$(cd "$SCRIPT_DIR/../.." && pwd)
for workflow in \
  "$repo_root/.github/workflows/kmp-publish-ios-snapshot.yml" \
  "$repo_root/.github/workflows/kmp-cleanup-ios-snapshots.yml"; do
  # shellcheck disable=SC2016
  assert_true "workflow must use the shared mutation concurrency group" \
    grep -Fq 'group: infomaniak-kmp-ios-snapshot-mutations-${{ github.repository }}' "$workflow"
  assert_true "workflow concurrency must not cancel in-progress mutations" \
    grep -Fq 'cancel-in-progress: false' "$workflow"
done

echo "All cleanup iOS snapshot tests passed"
