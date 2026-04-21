#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo bash install_crash_pusher.sh \
    --repo-branch main \
    [--cmmhi-cmd '/path/to/cmmhi_rtm -d']

Options:
  --repo-url URL            Git remote that will receive the logs. Default: git@github.com:Linfeng-He/machine_log.git
  --repo-branch BRANCH      Git branch to push to. Default: main
  --cmmhi-cmd CMD           Temperature command to run every second. Default: auto-discover cmmhi_rtm and run it with -d
  --host-id ID              Host label inside the repo. Default: hostname -s
  --state-dir DIR           Local working dir on target machine. Default: /var/lib/crash-pusher
  --snapshot-interval SEC   Seconds between system snapshots. Default: 1
  --push-interval SEC       Seconds between git commits/pushes after the initial push. Default: 5
  --staging-root DIR        Write files under DIR instead of /. Useful for local verification.
  --no-start                Install files but do not start the service.
  --stop                    Stop and disable the crash-pusher service.
  --skip-sampler            Do not download / install sampler.
  --help                    Show this help.

Examples:
  sudo bash install_crash_pusher.sh \
    --repo-branch main \
    --cmmhi-cmd '/opt/cmmhi/cmmhi_rtm -d'

  sudo bash install_crash_pusher.sh --repo-branch main

  bash install_crash_pusher.sh \
    --repo-url /tmp/crash-pusher-test-remote.git \
    --cmmhi-cmd 'printf "temp_c=42\n"' \
    --staging-root /tmp/crash-pusher-stage \
    --no-start

  sudo bash install_crash_pusher.sh --stop
EOF
}

die() {
  echo "install_crash_pusher.sh: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

prefix_path() {
  local path="$1"
  printf '%s%s\n' "${STAGING_ROOT%/}" "$path"
}

discover_cmmhi_cmd() {
  local roots=()
  local candidate=""
  local root

  if command -v cmmhi_rtm >/dev/null 2>&1; then
    printf '%s -d\n' "$(command -v cmmhi_rtm)"
    return 0
  fi

  for root in /usr/local /usr /opt /root /home /mnt; do
    [[ -d "$root" ]] && roots+=("$root")
  done

  if [[ "${#roots[@]}" -gt 0 ]]; then
    candidate="$(find "${roots[@]}" -maxdepth 6 -type f -name 'cmmhi_rtm' -perm -111 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "$candidate" ]]; then
    printf '%s -d\n' "$candidate"
  fi
}

write_runtime_runner() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

ENV_FILE="${CRASH_PUSHER_ENV_FILE:-/etc/default/crash-pusher}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

SERVICE_ROOT="${CRASH_PUSHER_SERVICE_ROOT:-/usr/local/lib/crash-pusher}"
TEMP_HELPER="${SERVICE_ROOT}/capture_temp.sh"

HOST_ID="${HOST_ID:-$(hostname -s)}"
HOST_ID="${CRASH_PUSHER_HOST_ID:-$HOST_ID}"
REPO_URL="${CRASH_PUSHER_REPO_URL:-${REPO_URL:-}}"
REPO_BRANCH="${CRASH_PUSHER_REPO_BRANCH:-${REPO_BRANCH:-main}}"
STATE_DIR="${CRASH_PUSHER_STATE_DIR:-${STATE_DIR:-/var/lib/crash-pusher}}"
if [[ -n "${CRASH_PUSHER_REPO_DIR:-}" ]]; then
  REPO_DIR="${CRASH_PUSHER_REPO_DIR}"
elif [[ -n "${CRASH_PUSHER_STATE_DIR:-}" ]]; then
  REPO_DIR="${STATE_DIR}/repo"
else
  REPO_DIR="${REPO_DIR:-${STATE_DIR}/repo}"
fi

if [[ -n "${CRASH_PUSHER_RUNTIME_DIR:-}" ]]; then
  RUNTIME_DIR="${CRASH_PUSHER_RUNTIME_DIR}"
elif [[ -n "${CRASH_PUSHER_STATE_DIR:-}" ]]; then
  RUNTIME_DIR="${STATE_DIR}/runtime"
else
  RUNTIME_DIR="${RUNTIME_DIR:-${STATE_DIR}/runtime}"
fi
SNAPSHOT_INTERVAL="${CRASH_PUSHER_SNAPSHOT_INTERVAL:-${SNAPSHOT_INTERVAL:-1}}"
PUSH_INTERVAL="${CRASH_PUSHER_PUSH_INTERVAL:-${PUSH_INTERVAL:-5}}"
GIT_AUTHOR_NAME="${CRASH_PUSHER_GIT_AUTHOR_NAME:-${GIT_AUTHOR_NAME:-crash-pusher}}"
GIT_AUTHOR_EMAIL="${CRASH_PUSHER_GIT_AUTHOR_EMAIL:-${GIT_AUTHOR_EMAIL:-crash-pusher@${HOST_ID}}}"

[[ -n "$REPO_URL" ]] || {
  echo "REPO_URL is not set in $ENV_FILE" >&2
  exit 1
}

mkdir -p "$STATE_DIR" "$RUNTIME_DIR"

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"
BOOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
SYS_ROOT_REL="sys"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

run_to_file() {
  local outfile="$1"
  shift
  if "$@" >"$outfile" 2>&1; then
    return 0
  fi
  printf '\ncommand_failed=%q\n' "$*" >>"$outfile"
  return 0
}

run_optional_cmd_to_file() {
  local outfile="$1"
  local cmd="$2"
  shift 2

  if command -v "$cmd" >/dev/null 2>&1; then
    run_to_file "$outfile" "$cmd" "$@"
  else
    {
      echo "command_missing=${cmd}"
      echo "timestamp_utc=$(date -u +%Y%m%dT%H%M%SZ)"
    } >"$outfile"
  fi

  sync_path "$outfile"
}

sync_path() {
  local path="$1"
  sync -f "$path" 2>/dev/null || sync 2>/dev/null || true
}

ensure_repo() {
  mkdir -p "$REPO_DIR"

  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL" || true
    git -C "$REPO_DIR" fetch origin "$REPO_BRANCH" >/dev/null 2>&1 || true
    git -C "$REPO_DIR" checkout "$REPO_BRANCH" >/dev/null 2>&1 || git -C "$REPO_DIR" checkout -B "$REPO_BRANCH" >/dev/null 2>&1
    git -C "$REPO_DIR" pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || true
    return
  fi

  if [[ -n "$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
    echo "REPO_DIR exists but is not a git repo: $REPO_DIR" >&2
    exit 1
  fi

  if git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR" >/dev/null 2>&1; then
    return
  fi

  git -c init.defaultBranch="$REPO_BRANCH" -C "$REPO_DIR" init >/dev/null
  git -C "$REPO_DIR" checkout -B "$REPO_BRANCH" >/dev/null
  git -C "$REPO_DIR" remote add origin "$REPO_URL"
}

append_boot_marker() {
  local outfile="$1"
  local label="$2"
  {
    echo
    echo "===== ${label} host=${HOST_ID} boot_started_utc=${BOOT_TS} boot_id=${BOOT_ID} ====="
  } >>"$outfile"
  sync_path "$outfile"
}

prepare_sys_tree() {
  local sys_root="$1"
  local hw_dir="${sys_root}/hw"
  local syslog_dir="${sys_root}/syslog"
  local journal_dir="${sys_root}/journal"
  local dmesg_dir="${sys_root}/dmesg"
  local temp_dir="${sys_root}/temp"
  local metadata_file="${journal_dir}/boot_meta_${BOOT_TS}_${BOOT_ID}.env"
  local status_log="${journal_dir}/system_status.log"
  local baseline_file="${journal_dir}/system_baseline_${BOOT_TS}.log"
  local boot_journal_file="${journal_dir}/boot_journal_${BOOT_TS}.log"
  local dmesg_file="${dmesg_dir}/dmesg_${BOOT_TS}.log"

  mkdir -p "$hw_dir" "$syslog_dir" "$journal_dir" "$dmesg_dir" "$temp_dir"

  {
    echo "host_id=${HOST_ID}"
    echo "boot_id=${BOOT_ID}"
    echo "boot_started_utc=${BOOT_TS}"
    echo "repo_branch=${REPO_BRANCH}"
    echo "kernel=$(uname -r)"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  } >"$metadata_file"
  sync_path "$metadata_file"

  append_boot_marker "$status_log" "system_status"
  append_boot_marker "${journal_dir}/journal.log" "journal"
  append_boot_marker "${dmesg_dir}/dmesg.log" "dmesg"
  append_boot_marker "${syslog_dir}/syslog.log" "syslog"

  {
    echo "===== system baseline host=${HOST_ID} boot_started_utc=${BOOT_TS} boot_id=${BOOT_ID} ====="
    echo
    echo "== uname =="
    uname -a
    echo
    echo "== os-release =="
    cat /etc/os-release
    echo
    echo "== cmdline =="
    cat /proc/cmdline
    echo
    echo "== lsblk =="
    lsblk -a
    echo
    echo "== df =="
    df -PTh
    echo
    echo "== free =="
    free -h
    echo
    echo "== ip addr =="
    ip addr
    echo
    echo "== ip route =="
    ip route
    echo
    echo "== failed units =="
    systemctl --failed --no-pager || true
    echo
    echo "== ps =="
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,comm --sort=-%cpu
    echo
    echo "== thermal sysfs =="
    for zone in /sys/class/thermal/thermal_zone*; do
      [[ -e "$zone" ]] || continue
      printf "%s type=%s temp=%s\n" "$zone" "$(cat "$zone/type" 2>/dev/null)" "$(cat "$zone/temp" 2>/dev/null)"
    done
  } >"$baseline_file"
  sync_path "$baseline_file"

  run_to_file "$boot_journal_file" journalctl -b --no-pager -n 400
  sync_path "$boot_journal_file"
  run_to_file "$dmesg_file" dmesg -T
  sync_path "$dmesg_file"
}

capture_hw_once() {
  local sys_root="$1"
  local hw_dir="${sys_root}/hw"

  run_optional_cmd_to_file "${hw_dir}/lshw.txt" lshw
  run_optional_cmd_to_file "${hw_dir}/dmi.txt" dmidecode
}

snapshot_once() {
  local sys_root="$1"
  local ts_file ts_iso
  ts_iso="$(date -u +%Y%m%dT%H%M%SZ)"
  ts_file="${sys_root}/journal/system_status.log"

  {
    echo
    echo "===== snapshot timestamp_utc=${ts_iso} host=${HOST_ID} boot_id=${BOOT_ID} ====="
    echo "timestamp_utc=${ts_iso}"
    echo
    echo "== uptime =="
    uptime
    echo
    echo "== loadavg =="
    cat /proc/loadavg
    echo
    echo "== meminfo =="
    awk '/MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback/ {print}' /proc/meminfo
    echo
    echo "== pressure =="
    for pressure_file in /proc/pressure/*; do
      [[ -e "$pressure_file" ]] || continue
      echo "-- $(basename "$pressure_file") --"
      cat "$pressure_file"
    done
    echo
    echo "== df =="
    df -PTh
    echo
    echo "== failed units =="
    systemctl --failed --no-pager || true
    echo
    echo "== top processes by cpu =="
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,comm --sort=-%cpu | head -n 40
    echo
    echo "== top processes by memory =="
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,comm --sort=-%mem | head -n 40
    echo
    echo "== sockets =="
    ss -tupan 2>/dev/null | head -n 120 || true
  } >>"$ts_file"

  sync_path "$ts_file"
}

capture_temperature_once() {
  local sys_root="$1"
  local ts_file ts_iso
  ts_iso="$(date -u +%Y%m%dT%H%M%SZ)"
  ts_file="${sys_root}/temp/${ts_iso}.txt"
  if [[ -x "$TEMP_HELPER" ]]; then
    "$TEMP_HELPER" >"$ts_file" 2>&1 || true
  else
    {
      echo "capture helper missing: $TEMP_HELPER"
      echo "timestamp_utc=${ts_iso}"
    } >"$ts_file"
  fi
  sync_path "$ts_file"
}

start_followers() {
  local sys_root="$1"
  JOURNAL_LOG="${sys_root}/journal/journal.log"
  KERNEL_LOG="${sys_root}/dmesg/dmesg.log"
  SYSLOG_LOG="${sys_root}/syslog/syslog.log"

  stdbuf -oL -eL journalctl -b -f -o short-iso --no-pager >>"$JOURNAL_LOG" 2>&1 &
  JOURNAL_PID=$!

  stdbuf -oL -eL journalctl -k -b -f -o short-iso --no-pager >>"$KERNEL_LOG" 2>&1 &
  KERNEL_PID=$!

  if [[ -f /var/log/syslog ]]; then
    stdbuf -oL -eL tail -n +1 -F /var/log/syslog >>"$SYSLOG_LOG" 2>&1 &
    SYSLOG_PID=$!
  else
    SYSLOG_PID=""
    SYSLOG_LOG=""
  fi
}

sync_live_logs_once() {
  for log_file in "${JOURNAL_LOG:-}" "${KERNEL_LOG:-}" "${SYSLOG_LOG:-}"; do
    [[ -n "$log_file" && -f "$log_file" ]] || continue
    sync_path "$log_file"
  done
}

stop_followers() {
  for pid_var in JOURNAL_PID KERNEL_PID SYSLOG_PID SNAPSHOT_PID TEMP_PID PUSH_PID LOG_SYNC_PID; do
    local pid="${!pid_var:-}"
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  wait || true
}

git_sync_once() {
  local now
  local staged_files
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  git -C "$REPO_DIR" add --all "$SYS_ROOT_REL"
  staged_files="$(git -C "$REPO_DIR" diff --cached --name-only)"
  if [[ -z "$staged_files" ]]; then
    return 0
  fi

  git -C "$REPO_DIR" pull --rebase --autostash origin "$REPO_BRANCH" >/dev/null 2>&1 || true
  git -C "$REPO_DIR" add --all "$SYS_ROOT_REL"

  staged_files="$(git -C "$REPO_DIR" diff --cached --name-only)"
  if [[ -z "$staged_files" ]]; then
    return 0
  fi

  git -C "$REPO_DIR" \
    -c user.name="$GIT_AUTHOR_NAME" \
    -c user.email="$GIT_AUTHOR_EMAIL" \
    commit -m "sys capture ${HOST_ID} ${BOOT_TS} ${now}" >/dev/null 2>&1 || true

  git -C "$REPO_DIR" push origin "$REPO_BRANCH" >/dev/null 2>&1 || true
}

main() {
  ensure_repo

  local sys_root="${REPO_DIR}/${SYS_ROOT_REL}"
  local cleanup_done=0

  cleanup() {
    [[ "$cleanup_done" -eq 1 ]] && return 0
    cleanup_done=1
    log "stopping"
    git_sync_once || true
    stop_followers
  }

  prepare_sys_tree "$sys_root"
  start_followers "$sys_root"
  trap cleanup EXIT INT TERM

  git_sync_once
  snapshot_once "$sys_root"
  git_sync_once
  capture_temperature_once "$sys_root"
  git_sync_once
  capture_hw_once "$sys_root"
  git_sync_once

  (
    while true; do
      snapshot_once "$sys_root"
      sleep "$SNAPSHOT_INTERVAL"
    done
  ) &
  SNAPSHOT_PID=$!

  (
    while true; do
      capture_temperature_once "$sys_root"
      sleep "$SNAPSHOT_INTERVAL"
    done
  ) &
  TEMP_PID=$!

  (
    while true; do
      sync_live_logs_once
      sleep "$SNAPSHOT_INTERVAL"
    done
  ) &
  LOG_SYNC_PID=$!

  (
    while true; do
      git_sync_once || true
      sleep "$PUSH_INTERVAL"
    done
  ) &
  PUSH_PID=$!

  wait "$SNAPSHOT_PID" "$TEMP_PID" "$PUSH_PID"
}

main "$@"
EOF
  chmod 0755 "$dest"
}

write_temp_helper() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${CRASH_PUSHER_ENV_FILE:-/etc/default/crash-pusher}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

CMMHI_CMD="${CMMHI_CMD:-}"
CMMHI_TIMEOUT="${CMMHI_TIMEOUT:-3}"

echo "timestamp_utc=$(date -u +%Y%m%dT%H%M%SZ)"
echo
echo "== cmmhi_rtm =="
if [[ -n "$CMMHI_CMD" ]]; then
  timeout "${CMMHI_TIMEOUT}" bash -lc "$CMMHI_CMD" 2>&1 || true
else
  echo "cmmhi_rtm not configured or not found"
fi

echo
echo "== thermal zones =="
for zone in /sys/class/thermal/thermal_zone*; do
  [[ -e "$zone" ]] || continue
  zone_type="$(cat "$zone/type" 2>/dev/null || echo unknown)"
  zone_temp="$(cat "$zone/temp" 2>/dev/null || echo unknown)"
  echo "${zone}: type=${zone_type} temp=${zone_temp}"
done

echo
echo "== hwmon =="
for sensor in /sys/class/hwmon/hwmon*/temp*_input; do
  [[ -e "$sensor" ]] || continue
  label_file="${sensor%_input}_label"
  if [[ -f "$label_file" ]]; then
    label="$(cat "$label_file" 2>/dev/null || true)"
  else
    label="$(basename "$sensor")"
  fi
  echo "${sensor}: label=${label} value=$(cat "$sensor" 2>/dev/null || echo unknown)"
done

echo
echo "== sensors =="
if command -v sensors >/dev/null 2>&1; then
  sensors 2>&1 || true
else
  echo "sensors command not installed"
fi
EOF
  chmod 0755 "$dest"
}

write_sampler_config() {
  local dest="$1"
  cat >"$dest" <<'EOF'
variables:
  env_file: /etc/default/crash-pusher
  temp_helper: /usr/local/lib/crash-pusher/capture_temp.sh

textboxes:
  - title: Temperature
    rate-ms: 1000
    sample: CRASH_PUSHER_ENV_FILE=$env_file $temp_helper

  - title: Failed Units
    rate-ms: 1000
    sample: systemctl --failed --no-pager

  - title: Recent Journal
    rate-ms: 1000
    sample: journalctl -b -n 20 -o short-iso --no-pager
EOF
}

write_service_file() {
  local dest="$1"
  cat >"$dest" <<'EOF'
[Unit]
Description=Crash log pusher
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=/etc/default/crash-pusher
ExecStart=/usr/local/lib/crash-pusher/runner.sh
Restart=always
RestartSec=2
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
}

quote_env_value() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ensure_hw_inventory_tools() {
  local missing=()
  local cmd

  for cmd in lshw dmidecode; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  if [[ -n "$STAGING_ROOT" ]]; then
    echo "staging note: missing hardware inventory commands: ${missing[*]}" >&2
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "warning: apt-get not found; hardware inventory commands missing: ${missing[*]}" >&2
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing[@]}"
}

ROOT_UID=0
REPO_URL="git@github.com:Linfeng-He/machine_log.git"
REPO_BRANCH="main"
CMMHI_CMD=""
HOST_ID="$(hostname -s)"
STATE_DIR="/var/lib/crash-pusher"
SNAPSHOT_INTERVAL="1"
PUSH_INTERVAL="5"
STAGING_ROOT=""
START_SERVICE=1
STOP_SERVICE_MODE=0
INSTALL_SAMPLER=1
SAMPLER_URL="https://github.com/sqshq/sampler/releases/download/v1.1.0/sampler-1.1.0-linux-amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --repo-branch)
      REPO_BRANCH="${2:-}"
      shift 2
      ;;
    --cmmhi-cmd)
      CMMHI_CMD="${2:-}"
      shift 2
      ;;
    --host-id)
      HOST_ID="${2:-}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --snapshot-interval)
      SNAPSHOT_INTERVAL="${2:-}"
      shift 2
      ;;
    --push-interval)
      PUSH_INTERVAL="${2:-}"
      shift 2
      ;;
    --staging-root)
      STAGING_ROOT="${2:-}"
      shift 2
      ;;
    --no-start)
      START_SERVICE=0
      shift
      ;;
    --stop)
      STOP_SERVICE_MODE=1
      shift
      ;;
    --skip-sampler)
      INSTALL_SAMPLER=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "$STOP_SERVICE_MODE" -eq 1 ]]; then
  if [[ -n "$STAGING_ROOT" ]]; then
    echo "staging mode: real stop command is:"
    echo "  sudo systemctl disable --now crash-pusher.service"
    exit 0
  fi

  if [[ "$(id -u)" -ne "$ROOT_UID" ]]; then
    die "--stop must run as root"
  fi

  require_cmd systemctl
  systemctl disable --now crash-pusher.service
  echo "crash-pusher.service stopped and disabled"
  exit 0
fi

require_cmd install
require_cmd git
require_cmd curl

if [[ -z "$STAGING_ROOT" ]] && [[ "$(id -u)" -ne "$ROOT_UID" ]]; then
  die "real installation must run as root"
fi

if [[ -n "$STAGING_ROOT" ]]; then
  mkdir -p "$STAGING_ROOT"
else
  STAGING_ROOT=""
fi

if [[ -z "$CMMHI_CMD" ]]; then
  CMMHI_CMD="$(discover_cmmhi_cmd || true)"
fi

BIN_DIR="$(prefix_path /usr/local/bin)"
LIB_DIR="$(prefix_path /usr/local/lib/crash-pusher)"
ETC_DEFAULT_DIR="$(prefix_path /etc/default)"
SYSTEMD_DIR="$(prefix_path /etc/systemd/system)"

install -d -m 0755 "$BIN_DIR" "$LIB_DIR" "$ETC_DEFAULT_DIR" "$SYSTEMD_DIR"

RUNNER_PATH="${LIB_DIR}/runner.sh"
TEMP_HELPER_PATH="${LIB_DIR}/capture_temp.sh"
SAMPLER_CONFIG_PATH="${LIB_DIR}/sampler.yml"
ENV_PATH="${ETC_DEFAULT_DIR}/crash-pusher"
SERVICE_PATH="${SYSTEMD_DIR}/crash-pusher.service"
SAMPLER_PATH="${BIN_DIR}/sampler"

write_runtime_runner "$RUNNER_PATH"
write_temp_helper "$TEMP_HELPER_PATH"
write_sampler_config "$SAMPLER_CONFIG_PATH"
write_service_file "$SERVICE_PATH"

cat >"$ENV_PATH" <<EOF
HOST_ID=$(quote_env_value "$HOST_ID")
REPO_URL=$(quote_env_value "$REPO_URL")
REPO_BRANCH=$(quote_env_value "$REPO_BRANCH")
STATE_DIR=$(quote_env_value "$STATE_DIR")
REPO_DIR=$(quote_env_value "${STATE_DIR}/repo")
RUNTIME_DIR=$(quote_env_value "${STATE_DIR}/runtime")
SNAPSHOT_INTERVAL=$(quote_env_value "$SNAPSHOT_INTERVAL")
PUSH_INTERVAL=$(quote_env_value "$PUSH_INTERVAL")
GIT_AUTHOR_NAME=$(quote_env_value "crash-pusher")
GIT_AUTHOR_EMAIL=$(quote_env_value "crash-pusher@${HOST_ID}")
CMMHI_CMD=$(quote_env_value "$CMMHI_CMD")
CMMHI_TIMEOUT=$(quote_env_value "3")
EOF
chmod 0600 "$ENV_PATH"

if [[ "$INSTALL_SAMPLER" -eq 1 ]]; then
  curl -fsSL "$SAMPLER_URL" -o "$SAMPLER_PATH"
  chmod 0755 "$SAMPLER_PATH"
fi

ensure_hw_inventory_tools

if [[ -z "$STAGING_ROOT" ]]; then
  systemctl daemon-reload
  systemctl enable crash-pusher.service
  if [[ "$START_SERVICE" -eq 1 ]]; then
    systemctl restart crash-pusher.service
  fi
else
  echo "staging install completed at $STAGING_ROOT"
  echo "manual runner test example:"
  echo "  CRASH_PUSHER_ENV_FILE=$ENV_PATH timeout 5s $RUNNER_PATH"
fi

echo "installer completed"
echo "environment file: $ENV_PATH"
echo "service file: $SERVICE_PATH"
echo "runner: $RUNNER_PATH"
echo "to stop later: sudo bash install_crash_pusher.sh --stop"
echo "manual stop command: sudo systemctl disable --now crash-pusher.service"
if [[ -n "$CMMHI_CMD" ]]; then
  echo "cmmhi command: $CMMHI_CMD"
else
  echo "cmmhi command: not found; helper will log sysfs and sensors data only until configured"
fi
if [[ "$INSTALL_SAMPLER" -eq 1 ]]; then
  echo "sampler: $SAMPLER_PATH"
  echo "sampler config: $SAMPLER_CONFIG_PATH"
fi
