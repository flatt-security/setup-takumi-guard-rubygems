#!/usr/bin/env bash
#
# Tests for how the action writes the rubygems.org mirror into Bundler's user
# configuration.
#
# The auth step is extracted from action.yml and run in anonymous mode, which
# needs no network. Cases 1 to 3, 5, 5b and 6 read the result back with
# `bundle config get`, so Bundler 2.1 or later must be on PATH. Cases 4 and 4b
# rely on file permissions and must run as a non-root user. Case 10 needs real
# symlinks.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACTION_YML="${ACTION_YML:-$REPO_ROOT/action.yml}"
WORK=$(mktemp -d)
AUTH_SCRIPT="$WORK/auth.sh"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

python3 "$REPO_ROOT/test/extract_script.py" "$ACTION_YML" auth > "$AUTH_SCRIPT"

KEY='BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/'
MIRROR_LINE="${KEY}: \"https://rubygems.flatt.tech/\""
FAILURES=0

start_case() {
  echo
  echo "=== $1 ==="
}

check() { # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1: $3"
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Files in a directory, sorted and space separated.
entries() {
  (cd "$1" && ls -A | sort | tr '\n' ' ' | sed 's/ $//')
}

# run_auth [VAR=value ...]
# Runs the auth step in anonymous mode with a fresh, empty TMPDIR and HOME
# unless the caller prepared $WORK/home. Extra arguments are passed to env;
# UMASK and SET_MIRROR are read from the caller's environment. Sets AUTH_EXIT;
# the log is $WORK/out.log.
run_auth() {
  rm -rf "$WORK/tmp" "$WORK/out.log"
  mkdir -p "$WORK/tmp" "$WORK/home"
  AUTH_EXIT=0
  env -i \
    PATH="${RUN_PATH:-$PATH}" \
    HOME="$WORK/home" \
    TMPDIR="$WORK/tmp" \
    BOT_ID="" \
    STS_URL="http://127.0.0.1:1" \
    AUDIENCE_INPUT="" \
    REGISTRY_URL="https://rubygems.flatt.tech" \
    EXPIRES_IN="1800" \
    SET_MIRROR="${SET_MIRROR:-true}" \
    GITHUB_OUTPUT="$WORK/github_output" \
    "$@" \
    bash -c 'umask "$0"; exec bash -e -o pipefail "$1"' "${UMASK:-022}" "$AUTH_SCRIPT" \
    > "$WORK/out.log" 2>&1 || AUTH_EXIT=$?
}

fresh_home() {
  chmod -R u+rwX "$WORK/home" 2>/dev/null
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home"
}

bundle_get() { # <setting> [VAR=value ...] -> the value Bundler resolves, with HOME=$WORK/home
  local setting=$1; shift
  (cd "$WORK" && env HOME="$WORK/home" "$@" bundle config get --parseable "$setting" 2>/dev/null) \
    | awk -v k="$setting=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'
}

if [ "$(id -u)" = 0 ]; then
  echo "FATAL: run as a non-root user; root can read and write files with any mode"
  exit 1
fi
command -v bundle >/dev/null || { echo "FATAL: bundle is not on PATH"; exit 1; }

# --- 1: no configuration file --------------------------------------------------
start_case "1: creates the configuration file and Bundler reads the mirror"
fresh_home
run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "file" "$(printf -- '---\n%s' "$MIRROR_LINE")" "$(cat "$WORK/home/.bundle/config")"
check "Bundler resolves the mirror" "https://rubygems.flatt.tech/" "$(bundle_get mirror.https://rubygems.org)"

# --- 2: existing settings ------------------------------------------------------
start_case "2: replaces the old mirror line and keeps every other line"
fresh_home
mkdir -p "$WORK/home/.bundle"
cat > "$WORK/home/.bundle/config" <<EOF
---
BUNDLE_JOBS: "4"
${KEY}: "https://old.example/"
BUNDLE_NOTE: "${KEY}: kept because the key is not at the start of the line"
BUNDLE_PATH: "vendor/bundle"
EOF
run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "mirror lines" 1 "$(grep -c "^${KEY}:" "$WORK/home/.bundle/config")"
check "mirror value" "https://rubygems.flatt.tech/" "$(bundle_get mirror.https://rubygems.org)"
check "other lines kept" 4 "$(grep -c -e '^---$' -e '^BUNDLE_JOBS: "4"$' -e '^BUNDLE_NOTE: ' -e '^BUNDLE_PATH: "vendor/bundle"$' "$WORK/home/.bundle/config")"
check "Bundler still reads jobs" 4 "$(bundle_get jobs)"

# --- 3: empty file -------------------------------------------------------------
start_case "3: an empty configuration file"
fresh_home
mkdir -p "$WORK/home/.bundle"
: > "$WORK/home/.bundle/config"
run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "mirror value" "https://rubygems.flatt.tech/" "$(bundle_get mirror.https://rubygems.org)"

# --- 4: unreadable file --------------------------------------------------------
start_case "4: an unreadable configuration file fails and is left as it was"
fresh_home
mkdir -p "$WORK/home/.bundle"
printf -- '---\nBUNDLE_JOBS: "4"\n' > "$WORK/home/.bundle/config"
chmod 000 "$WORK/home/.bundle/config"
run_auth
chmod 600 "$WORK/home/.bundle/config"
check "auth exit" 1 "$AUTH_EXIT"
check "reason" 1 "$(grep -c "cannot read ${WORK}/home/.bundle/config" "$WORK/out.log")"
check "file unchanged" "$(printf -- '---\nBUNDLE_JOBS: "4"')" "$(cat "$WORK/home/.bundle/config")"

# --- 4b: read-only file ---------------------------------------------------------
# The file is readable and its directory writable, so the step gets as far as
# its temporary file before the write fails.
start_case "4b: a read-only configuration file fails, is left as it was, and nothing is left behind"
fresh_home
mkdir -p "$WORK/home/.bundle"
printf -- '---\nBUNDLE_JOBS: "4"\n' > "$WORK/home/.bundle/config"
chmod 444 "$WORK/home/.bundle/config"
run_auth
check "auth exit" 1 "$AUTH_EXIT"
check "reason" 1 "$(grep -c "cannot write ${WORK}/home/.bundle/config" "$WORK/out.log")"
check "file unchanged" "$(printf -- '---\nBUNDLE_JOBS: "4"')" "$(cat "$WORK/home/.bundle/config")"
check "TMPDIR" "" "$(entries "$WORK/tmp")"
check "configuration directory" "config" "$(entries "$WORK/home/.bundle")"

# --- 5: BUNDLE_USER_CONFIG ------------------------------------------------------
start_case "5: BUNDLE_USER_CONFIG names the file"
fresh_home
run_auth BUNDLE_USER_CONFIG="$WORK/home/elsewhere/bundler.yml"
check "auth exit" 0 "$AUTH_EXIT"
check "written to BUNDLE_USER_CONFIG" 1 "$(grep -cF "$MIRROR_LINE" "$WORK/home/elsewhere/bundler.yml" 2>/dev/null)"
check "~/.bundle/config" "absent" "$([ -e "$WORK/home/.bundle/config" ] && echo present || echo absent)"
check "Bundler resolves the mirror" "https://rubygems.flatt.tech/" \
  "$(bundle_get mirror.https://rubygems.org BUNDLE_USER_CONFIG="$WORK/home/elsewhere/bundler.yml")"

# --- 5b: BUNDLE_CONFIG ------------------------------------------------------------
# Bundler reads BUNDLE_CONFIG before BUNDLE_USER_CONFIG, so with both set the
# mirror must go to BUNDLE_CONFIG.
start_case "5b: BUNDLE_CONFIG names the file and wins over BUNDLE_USER_CONFIG"
fresh_home
run_auth BUNDLE_CONFIG="$WORK/home/bundle-config.yml" BUNDLE_USER_CONFIG="$WORK/home/user-config.yml"
check "auth exit" 0 "$AUTH_EXIT"
check "written to BUNDLE_CONFIG" 1 "$(grep -cF "$MIRROR_LINE" "$WORK/home/bundle-config.yml" 2>/dev/null)"
check "BUNDLE_USER_CONFIG file" "absent" "$([ -e "$WORK/home/user-config.yml" ] && echo present || echo absent)"
check "~/.bundle/config" "absent" "$([ -e "$WORK/home/.bundle/config" ] && echo present || echo absent)"
check "Bundler resolves the mirror" "https://rubygems.flatt.tech/" \
  "$(bundle_get mirror.https://rubygems.org BUNDLE_CONFIG="$WORK/home/bundle-config.yml" BUNDLE_USER_CONFIG="$WORK/home/user-config.yml")"

# --- 6: BUNDLE_USER_HOME --------------------------------------------------------
start_case "6: BUNDLE_USER_HOME names the directory"
fresh_home
run_auth BUNDLE_USER_HOME="$WORK/home/bundle-home"
check "auth exit" 0 "$AUTH_EXIT"
check "written to BUNDLE_USER_HOME/config" 1 "$(grep -cF "$MIRROR_LINE" "$WORK/home/bundle-home/config" 2>/dev/null)"
check "~/.bundle/config" "absent" "$([ -e "$WORK/home/.bundle/config" ] && echo present || echo absent)"
check "Bundler resolves the mirror" "https://rubygems.flatt.tech/" \
  "$(bundle_get mirror.https://rubygems.org BUNDLE_USER_HOME="$WORK/home/bundle-home")"

# --- 7: no Bundler --------------------------------------------------------------
start_case "7: works when Bundler is not installed"
fresh_home
mkdir -p "$WORK/bin"
for tool in bash sed awk mktemp cat mkdir dirname rm; do
  ln -sf "$(command -v "$tool")" "$WORK/bin/$tool"
done
RUN_PATH="$WORK/bin" run_auth
check "bundle on the step's PATH" "none" "$(PATH="$WORK/bin" command -v bundle || echo none)"
check "auth exit" 0 "$AUTH_EXIT"
check "file written" 1 "$(grep -cF "$MIRROR_LINE" "$WORK/home/.bundle/config" 2>/dev/null)"

# --- 8: permissions -------------------------------------------------------------
start_case "8: keeps the mode of an existing file, and a new file follows the umask"
fresh_home
mkdir -p "$WORK/home/.bundle"
printf -- '---\n' > "$WORK/home/.bundle/config"
chmod 604 "$WORK/home/.bundle/config"
run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "existing file mode" 604 "$(mode_of "$WORK/home/.bundle/config")"
for pair in 022:644 077:600; do
  fresh_home
  UMASK=${pair%%:*} run_auth
  check "auth exit (umask ${pair%%:*})" 0 "$AUTH_EXIT"
  check "new file mode (umask ${pair%%:*})" "${pair##*:}" "$(mode_of "$WORK/home/.bundle/config")"
done

# --- 9: nothing left behind -------------------------------------------------------
start_case "9: a successful run leaves no temporary file"
fresh_home
run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "TMPDIR" "" "$(entries "$WORK/tmp")"
check "configuration directory" "config" "$(entries "$WORK/home/.bundle")"

# --- 10: symlink -----------------------------------------------------------------
start_case "10: a symlinked configuration file is written through the link"
fresh_home
mkdir -p "$WORK/home/.bundle" "$WORK/home/dotfiles"
printf -- '---\nBUNDLE_JOBS: "4"\n' > "$WORK/home/dotfiles/bundle-config"
ln -s "$WORK/home/dotfiles/bundle-config" "$WORK/home/.bundle/config"
run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "still a symlink" "yes" "$([ -L "$WORK/home/.bundle/config" ] && echo yes || echo no)"
check "link target written" 1 "$(grep -cF "$MIRROR_LINE" "$WORK/home/dotfiles/bundle-config")"

# --- 11: set-mirror false ---------------------------------------------------------
start_case "11: set-mirror false writes nothing"
fresh_home
SET_MIRROR=false run_auth
check "auth exit" 0 "$AUTH_EXIT"
check "~/.bundle" "absent" "$([ -e "$WORK/home/.bundle" ] && echo present || echo absent)"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all mirror tests passed"
else
  echo "${FAILURES} check(s) failed"
fi
exit $((FAILURES > 0))
