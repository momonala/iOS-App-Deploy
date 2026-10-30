#!/usr/bin/env bash
#
# Build one of the apps in config.json and install it on the configured iPhone over USB or wifi.
# See --help for usage.

set -euo pipefail

REDEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REDEPLOY_CONFIG:-$REDEPLOY_ROOT/config.json}"
INSTALLED_DIR="$HOME/Library/Application Support/Redeploy/installed"
# `cert-exp` is a zsh alias, so a non-interactive script has to call the project behind it.
CERT_EXP_PROJECT="$HOME/code/projects/certificate-expiration"

CONFIGURATION="Release"
DEVICE_QUERY=""
LAUNCH=true
CLEAN=false
CERTS=true
RETRIES=3
APP_ID=""

# Kept for the SSH guard, which re-suggests the invocation after the args have been shifted away.
ORIGINAL_ARGS=("$@")

# ---------------------------------------------------------------------------- output

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

LOG_FILE="${REDEPLOY_LOG_FILE:-$(mktemp -t ios-deploy)}"

STEP=0
TOTAL_STEPS=3
step()  { STEP=$((STEP + 1)); printf '\n%s[%d/%d]%s %s%s%s\n' "$BLUE" "$STEP" "$TOTAL_STEPS" "$RESET" "$BOLD" "$1" "$RESET"; }
info()  { printf '      %s\n' "$1"; }
detail(){ printf '      %s%s%s\n' "$DIM" "$1" "$RESET"; }
ok()    { printf '      %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()  { printf '      %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
die()   { printf '\n%serror%s %s\n' "$RED" "$RESET" "$1" >&2; printf '%sfull log: %s%s\n' "$DIM" "$LOG_FILE" "$RESET" >&2; exit 1; }

# Seconds since the epoch, for per-step timings.
now()      { date +%s; }
elapsed()  { printf '%ss' "$(( $(now) - $1 ))"; }

usage() {
    cat <<EOF
${BOLD}iOS deploy${RESET} — build an app from config.json and install it on the configured iPhone.

${BOLD}usage${RESET}
  deploy-ios.sh APP [options]

  APP is an id from $CONFIG: $(jq -r '[.apps[].id] | join(", ")' "$CONFIG" 2>/dev/null || echo "?")

${BOLD}options${RESET}
  -d, --device NAME|UDID     device to target; default is the one in config.json
  -c, --configuration NAME   Release (default) or Debug
      --no-launch            install but do not launch
      --clean                delete DerivedData before building
      --no-certs             skip both provisioning-profile steps
  -h, --help                 show this help

${BOLD}steps${RESET}
  find the device, clear provisioning profiles, build, install, launch, check certificate expiry

Clearing profiles and the expiry check shell out to cert-exp: profiles are cleared before the build
so Xcode fetches fresh ones, then the new expiry dates are recorded afterwards. Either failing aborts
the deploy. A successful install is recorded in $INSTALLED_DIR,
which is where the iOS App Deploy menu bar app reads expiry dates from.

${BOLD}environment${RESET}
  DEVELOPER_DIR        Xcode toolchain to use; resolved automatically when unset
  NO_COLOR             disable coloured output
  REDEPLOY_LOG_FILE    where full xcodebuild output goes; a temp file when unset
  REDEPLOY_ALLOW_SSH   set to 1 to run over SSH anyway, after unlocking the login keychain
EOF
    exit 0
}

# cert-exp with no subcommand reports expiry dates; `clear` empties the profiles directory.
# Any failure aborts the deploy — a silently skipped clear means building against a stale profile,
# and a silently skipped report means no expiry warning lands in the calendar. Use --no-certs to opt
# out deliberately.
cert_exp() {
    [[ -d "$CERT_EXP_PROJECT" ]] || die "cert-exp project not found at $CERT_EXP_PROJECT (--no-certs to skip)"
    command -v uv >/dev/null || die "uv not on PATH, needed to run cert-exp (--no-certs to skip)"
    uv run --project "$CERT_EXP_PROJECT" cert-exp "$@" || die "cert-exp $* failed"
}

# ---------------------------------------------------------------------------- args

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)        DEVICE_QUERY="${2:-}"; shift 2 ;;
        -c|--configuration) CONFIGURATION="${2:-}"; shift 2 ;;
        --no-launch)        LAUNCH=false; shift ;;
        --clean)            CLEAN=true; shift ;;
        --no-certs)         CERTS=false; shift ;;
        -h|--help)          usage ;;
        -*)                 die "unknown argument: $1 (try --help)" ;;
        *)
            [[ -z "$APP_ID" ]] || die "only one APP at a time (got '$APP_ID' and '$1')"
            APP_ID="$1"; shift ;;
    esac
done

[[ "$CERTS" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
[[ "$LAUNCH" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

# ---------------------------------------------------------------------------- config

command -v jq >/dev/null || die "jq not on PATH, needed to read $CONFIG and devicectl output"
[[ -f "$CONFIG" ]] || die "config not found at $CONFIG"
[[ -n "$APP_ID" ]] || die "no APP given (try --help)"

app_field() { jq -er --arg id "$APP_ID" --arg key "$1" '.apps[] | select(.id == $id) | .[$key]' "$CONFIG"; }

APP_NAME="$(app_field name)" || die "no app '$APP_ID' in $CONFIG"
REPO_ROOT="$(app_field repo)"
REPO_ROOT="${REPO_ROOT/#\~/$HOME}"
PROJECT="$REPO_ROOT/$(app_field project)"
SCHEME="$(app_field scheme)"
BUNDLE_ID="$(app_field bundleId)"
DERIVED_DATA="$REPO_ROOT/build/DerivedData-device"
DEFAULT_DEVICE_NAME="$(jq -r '.device.name' "$CONFIG")"
DEFAULT_DEVICE_UDID="$(jq -r '.device.udid' "$CONFIG")"

[[ -d "$PROJECT" ]] || die "Xcode project not found at $PROJECT"

# ---------------------------------------------------------------------------- session

# Code signing reads the Apple ID account out of the login keychain, which macOS only unlocks at GUI
# login. Over SSH the keychain stays locked, so xcodebuild sees no accounts and fails halfway through
# the build with "No Accounts" and "No profiles for ...". Fail fast here instead, and say how to get
# a signable session. REDEPLOY_ALLOW_SSH=1 overrides once the keychain has been unlocked by hand.
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" && "${REDEPLOY_ALLOW_SSH:-}" != 1 ]]; then
    die "running over SSH — the login keychain is locked, so the build cannot be code signed.
      Run this on the Mac itself, or from the SSH session either

        launchctl asuser $(id -u) $(command -v bash) ${BASH_SOURCE[0]} ${ORIGINAL_ARGS[*]:-}

      to borrow the already-unlocked GUI session, or unlock the keychain first and re-run with
      REDEPLOY_ALLOW_SSH=1:

        security unlock-keychain ~/Library/Keychains/login.keychain-db"
fi

# ---------------------------------------------------------------------------- toolchain

# xcode-select often points at CommandLineTools, which has no xcodebuild or devicectl.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$selected" == *"/Xcode.app/"* ]]; then
        export DEVELOPER_DIR="$selected"
    elif [[ -d /Applications/Xcode.app ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        die "no Xcode.app found — install Xcode or set DEVELOPER_DIR"
    fi
fi
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
[[ -x "$XCODEBUILD" ]] || die "xcodebuild missing at $XCODEBUILD"

printf '%s%s%s deploy%s  %s%s / %s%s\n' "$BOLD" "$CYAN" "$APP_NAME" "$RESET" "$DIM" "$SCHEME" "$CONFIGURATION" "$RESET"
detail "developer dir: $DEVELOPER_DIR"
detail "log:           $LOG_FILE"

# ---------------------------------------------------------------------------- device

deploy_start=$(now)

step "Finding the device"
device_start=$(now)

devices_json="$(mktemp -t ios-deploy-devices)"
xcrun devicectl list devices --json-output "$devices_json" >>"$LOG_FILE" 2>&1 \
    || die "devicectl list devices failed — is Xcode's device support installed?"

# Simulators show up in devicectl too, so keep physical devices only. A device the table calls
# "available" or "connected" has a transportType (localNetwork, wired); an "unavailable" one has none.
matches="$(jq -r '
    .result.devices[]
    | select(.visibilityClass != "simulators" and .hardwareProperties.reality != "simulated")
    | select(.hardwareProperties.platform == "iOS")
    | select(.connectionProperties.pairingState == "paired" and .connectionProperties.transportType != null)
    | "\(.deviceProperties.name)\t\(.hardwareProperties.udid)"
' "$devices_json")"
rm -f "$devices_json"

if [[ -n "$DEVICE_QUERY" ]]; then
    matches="$(printf '%s\n' "$matches" | grep -i -- "$DEVICE_QUERY" || true)"
    [[ -n "$matches" ]] || die "no usable device matching '$DEVICE_QUERY'"
    device_count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    [[ "$device_count" -gt 1 ]] && warn "$device_count devices matched; using the first (narrow it with -d)"
else
    matches="$(printf '%s\n' "$matches" | awk -F '\t' -v udid="$DEFAULT_DEVICE_UDID" '$2 == udid' || true)"
    [[ -n "$matches" ]] || die "$DEFAULT_DEVICE_NAME is not reachable — unlock the phone and check it is on the same wifi"
fi

DEVICE_NAME="$(printf '%s\n' "$matches" | head -1 | cut -f1)"
DEVICE_UDID="$(printf '%s\n' "$matches" | head -1 | cut -f2)"

ok "$DEVICE_NAME"
detail "$DEVICE_UDID"
detail "took $(elapsed "$device_start")"

# ---------------------------------------------------------------------------- profiles

if [[ "$CERTS" == true ]]; then
    step "Clearing provisioning profiles"
    # Emptied before the build so -allowProvisioningUpdates fetches fresh profiles rather than
    # reusing a stale one that is about to expire.
    detail "cert-exp clear"
    cert_exp clear
fi

# ---------------------------------------------------------------------------- build

step "Building"
build_start=$(now)

if [[ "$CLEAN" == true ]]; then
    info "removing $DERIVED_DATA"
    rm -rf "$DERIVED_DATA"
fi

# 'generic/platform=iOS' rather than 'id=<udid>': the id form makes xcodebuild wait on device
# preparation and it times out on a locked phone, even when install would have worked fine.
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
info "xcodebuild $SCHEME ($CONFIGURATION) build $BUILD_NUMBER for generic/platform=iOS"
if ! "$XCODEBUILD" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        build >>"$LOG_FILE" 2>&1; then
    printf '\n'
    # Compiler diagnostics first — the tail of an xcodebuild log is almost never the useful part.
    if grep -qE 'error:' "$LOG_FILE"; then
        grep -E 'error:' "$LOG_FILE" \
            | sed "s|$REPO_ROOT/||" \
            | sort -u \
            | head -15 \
            | sed "s|^|      ${RED}✗${RESET} |"
    else
        detail "no 'error:' lines in the log — last 30 lines instead:"
        tail -30 "$LOG_FILE" | sed 's/^/      /'
    fi
    die "build failed"
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/$SCHEME.app"
[[ -d "$APP_PATH" ]] || die "build succeeded but $APP_PATH is missing"

ok "built $(du -sh "$APP_PATH" | cut -f1 | tr -d ' ')"
detail "$APP_PATH"
detail "took $(elapsed "$build_start")"

# ---------------------------------------------------------------------------- install

# The wifi tunnel to the device drops often enough that a single failure means nothing.
# Usage: retry <what> <command...>
retry() {
    local what="$1"; shift
    local attempt=1
    while true; do
        if "$@" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        if [[ $attempt -ge $RETRIES ]]; then
            tail -15 "$LOG_FILE" | sed 's/^/      /'
            die "$what failed after $RETRIES attempts"
        fi
        warn "$what attempt $attempt failed, retrying in 3s (usually a dropped wifi tunnel)"
        attempt=$((attempt + 1))
        sleep 3
    done
}

# The profile embedded in the build is what now runs on the phone, so a copy of it is the record of
# when this install expires. Written here rather than by the menu bar app so terminal deploys count.
record_install() {
    mkdir -p "$INSTALLED_DIR"
    cp "$APP_PATH/embedded.mobileprovision" "$INSTALLED_DIR/$BUNDLE_ID.mobileprovision"
    local dirty=false
    [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]] && dirty=true
    jq -n \
        --arg installedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg commit "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        --arg subject "$(git -C "$REPO_ROOT" log -1 --format=%s 2>/dev/null || echo unknown)" \
        --arg branch "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)" \
        --argjson dirty "$dirty" \
        --arg device "$DEVICE_NAME" \
        --arg configuration "$CONFIGURATION" \
        --arg version "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Info.plist" 2>/dev/null || echo "?")" \
        --arg build "$(plutil -extract CFBundleVersion raw "$APP_PATH/Info.plist" 2>/dev/null || echo "?")" \
        --argjson durationSeconds "$(( $(now) - deploy_start ))" \
        '$ARGS.named' >"$INSTALLED_DIR/$BUNDLE_ID.json"
}

step "Installing on $DEVICE_NAME"
install_start=$(now)
retry "install" xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"
record_install
ok "installed $BUNDLE_ID"
detail "took $(elapsed "$install_start")"

# ---------------------------------------------------------------------------- launch

if [[ "$LAUNCH" == true ]]; then
    step "Launching"
    launch_start=$(now)
    retry "launch" xcrun devicectl device process launch \
        --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID"
    ok "running on $DEVICE_NAME"
    detail "took $(elapsed "$launch_start")"
fi

# ---------------------------------------------------------------------------- cert expiry

if [[ "$CERTS" == true ]]; then
    step "Checking certificate expiry"
    # The app bundle's own profile is the one now on the phone, so its date is the one to record.
    detail "cert-exp --profile embedded.mobileprovision"
    cert_exp --profile "$APP_PATH/embedded.mobileprovision"
fi

printf '\n%s%sDone.%s %sconfig=%s  device=%s  log=%s%s\n\n' \
    "$BOLD" "$GREEN" "$RESET" "$DIM" "$CONFIGURATION" "$DEVICE_NAME" "$LOG_FILE" "$RESET"
