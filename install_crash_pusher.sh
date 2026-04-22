#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo bash install_crash_pusher.sh \
    [--cmmhi-cmd '/path/to/cmmhi_rtm -d']

Options:
  --repo-dir DIR            Git repo that receives the sys updates. Default: git repo containing this script
  --repo-url URL            Optional override for the repo's origin remote. Default: keep existing origin
  --repo-branch BRANCH      Git branch to push to. Default: current branch of the cloned repo
  --cmmhi-cmd CMD           Temperature command to run every second. Default: auto-discover cmmhi_rtm and run it with -d
  --host-id ID              Host label inside the repo. Default: hostname -s
  --snapshot-interval SEC   Seconds between system snapshots. Default: 1
  --push-interval SEC       Seconds between git commits/pushes after the initial push. Default: 20
  --staging-root DIR        Write files under DIR instead of /. Useful for local verification.
  --no-start                Install files but do not start the service.
  --stop                    Stop and disable the crash-pusher service.
  --skip-sampler            Do not download / install sampler.
  --help                    Show this help.

Examples:
  sudo bash install_crash_pusher.sh \
    --cmmhi-cmd '/opt/cmmhi/cmmhi_rtm -d'

  bash install_crash_pusher.sh \
    --repo-dir /tmp/machine_log \
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

script_dir() {
  local source_path="${BASH_SOURCE[0]:-$0}"
  local source_dir
  source_dir="$(cd -- "$(dirname -- "$source_path")" && pwd -P)"
  printf '%s\n' "$source_dir"
}

discover_repo_dir() {
  local start_dir="$1"
  if git -C "$start_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$start_dir" rev-parse --show-toplevel
    return 0
  fi
  printf '%s\n' "$start_dir"
}

current_repo_branch() {
  local repo_dir="$1"
  git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

discover_cmmhi_cmd() {
  local roots=()
  local seen_roots=""
  local candidate=""
  local root
  local parent_dir=""

  add_search_root() {
    local candidate_root="$1"
    [[ -n "$candidate_root" ]] || return 0
    [[ -d "$candidate_root" ]] || return 0
    case ",${seen_roots}," in
      *,"${candidate_root}",*) return 0 ;;
    esac
    roots+=("$candidate_root")
    seen_roots+=",${candidate_root}"
  }

  if command -v cmmhi_rtm >/dev/null 2>&1; then
    printf '%s -d\n' "$(command -v cmmhi_rtm)"
    return 0
  fi

  for root in /usr/local /usr /opt /mnt; do
    add_search_root "$root"
  done

  add_search_root "${HOME:-}"

  while IFS=: read -r _ _ _ _ _ passwd_home _; do
    [[ -n "$passwd_home" ]] || continue
    add_search_root "$passwd_home"
    parent_dir="$(dirname "$passwd_home")"
    add_search_root "$parent_dir"
  done < <(getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true)

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
REPO_DIR="${CRASH_PUSHER_REPO_DIR:-${REPO_DIR:-}}"
REPO_URL="${CRASH_PUSHER_REPO_URL:-${REPO_URL:-}}"
REPO_BRANCH="${CRASH_PUSHER_REPO_BRANCH:-${REPO_BRANCH:-}}"
SNAPSHOT_INTERVAL="${CRASH_PUSHER_SNAPSHOT_INTERVAL:-${SNAPSHOT_INTERVAL:-1}}"
PUSH_INTERVAL="${CRASH_PUSHER_PUSH_INTERVAL:-${PUSH_INTERVAL:-20}}"
GIT_AUTHOR_NAME="${CRASH_PUSHER_GIT_AUTHOR_NAME:-${GIT_AUTHOR_NAME:-crash-pusher}}"
GIT_AUTHOR_EMAIL="${CRASH_PUSHER_GIT_AUTHOR_EMAIL:-${GIT_AUTHOR_EMAIL:-crash-pusher@${HOST_ID}}}"

[[ -n "$REPO_DIR" ]] || {
  echo "REPO_DIR is not set in $ENV_FILE" >&2
  exit 1
}

REPO_OWNER_USER="$(stat -c %U "$REPO_DIR" 2>/dev/null || true)"
REPO_OWNER_UID="$(stat -c %u "$REPO_DIR" 2>/dev/null || true)"

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

log_multiline() {
  local prefix="$1"
  local text="$2"
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    log "${prefix}${line}"
  done <<<"$text"
}

run_git() {
  local -a preserved_env=()

  for env_name in SSH_AUTH_SOCK GIT_ASKPASS SSH_ASKPASS DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_HANDLE ELECTRON_RUN_AS_NODE; do
    if [[ -n "${!env_name:-}" ]]; then
      preserved_env+=("${env_name}=${!env_name}")
    fi
  done

  if [[ -n "$REPO_OWNER_UID" && "$(id -u)" -eq "$REPO_OWNER_UID" ]]; then
    env "${preserved_env[@]}" GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new}" git "$@"
    return $?
  fi

  if [[ -n "$REPO_OWNER_USER" && "$REPO_OWNER_USER" != "UNKNOWN" ]] && command -v sudo >/dev/null 2>&1; then
    sudo -H -u "$REPO_OWNER_USER" env "${preserved_env[@]}" GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new}" git "$@"
    return $?
  fi

  env "${preserved_env[@]}" GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new}" git "$@"
}

ensure_repo() {
  [[ -d "$REPO_DIR/.git" ]] || {
    echo "REPO_DIR is not a git repo: $REPO_DIR" >&2
    exit 1
  }

  log "git user: ${REPO_OWNER_USER:-unknown}"

  if [[ -n "$REPO_URL" ]]; then
    if run_git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
      run_git -C "$REPO_DIR" remote set-url origin "$REPO_URL" >/dev/null 2>&1 || true
    else
      run_git -C "$REPO_DIR" remote add origin "$REPO_URL" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -z "$REPO_BRANCH" ]]; then
    REPO_BRANCH="$(run_git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  fi

  if [[ -z "$REPO_BRANCH" ]]; then
    REPO_BRANCH="$(run_git -C "$REPO_DIR" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  fi

  if [[ -z "$REPO_BRANCH" || "$REPO_BRANCH" == "HEAD" ]]; then
    REPO_BRANCH="main"
  fi
}

check_push_access() {
  local remote_url=""
  local push_output=""

  if ! run_git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    log "origin remote is not configured; commits will stay local"
    return 0
  fi

  remote_url="$(run_git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  log "origin remote: ${remote_url}"

  push_output="$(run_git -C "$REPO_DIR" push --dry-run origin "$REPO_BRANCH" 2>&1)" || {
    log "push preflight failed for origin/${REPO_BRANCH}"
    log_multiline "push preflight: " "$push_output"
    if [[ "$remote_url" == https://github.com/* ]]; then
      log "github https remote detected; configure a credential helper/token or switch origin to ssh for unattended pushes"
    fi
    return 0
  }
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
  local metadata_file="${journal_dir}/boot_meta.env"
  local status_log="${journal_dir}/system_status.log"
  local baseline_file="${journal_dir}/system_baseline.log"
  local journal_file="${journal_dir}/journal.log"
  local dmesg_file="${dmesg_dir}/dmesg.log"
  local syslog_file="${syslog_dir}/syslog.log"
  local temp_file="${temp_dir}/temperature.log"

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
  : >"$journal_file"
  : >"$dmesg_file"
  : >"$syslog_file"
  : >"$temp_file"
  sync_path "$journal_file"
  sync_path "$dmesg_file"
  sync_path "$syslog_file"
  sync_path "$temp_file"

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
  ts_file="${sys_root}/temp/temperature.log"
  {
    echo
    echo "===== temperature timestamp_utc=${ts_iso} host=${HOST_ID} boot_id=${BOOT_ID} ====="
  } >>"$ts_file"
  if [[ -x "$TEMP_HELPER" ]]; then
    "$TEMP_HELPER" >>"$ts_file" 2>&1 || true
  else
    {
      echo "capture helper missing: $TEMP_HELPER"
      echo "timestamp_utc=${ts_iso}"
    } >>"$ts_file"
  fi
  sync_path "$ts_file"
}

refresh_journal_once() {
  local sys_root="$1"
  local outfile="${sys_root}/journal/journal.log"
  {
    echo "===== journal snapshot host=${HOST_ID} boot_started_utc=${BOOT_TS} boot_id=${BOOT_ID} captured_utc=$(date -u +%Y%m%dT%H%M%SZ) ====="
    echo
    journalctl -b --no-pager -n 400
  } >"$outfile" 2>&1 || true
  sync_path "$outfile"
}

refresh_dmesg_once() {
  local sys_root="$1"
  local outfile="${sys_root}/dmesg/dmesg.log"
  {
    echo "===== dmesg snapshot host=${HOST_ID} boot_started_utc=${BOOT_TS} boot_id=${BOOT_ID} captured_utc=$(date -u +%Y%m%dT%H%M%SZ) ====="
    echo
    dmesg -T
  } >"$outfile" 2>&1 || true
  sync_path "$outfile"
}

refresh_syslog_once() {
  local sys_root="$1"
  local outfile="${sys_root}/syslog/syslog.log"
  if [[ -f /var/log/syslog ]]; then
    {
      echo "===== syslog snapshot host=${HOST_ID} boot_started_utc=${BOOT_TS} boot_id=${BOOT_ID} captured_utc=$(date -u +%Y%m%dT%H%M%SZ) ====="
      echo
      cat /var/log/syslog
    } >"$outfile" 2>&1 || true
  else
    {
      echo "syslog_missing=/var/log/syslog"
      echo "timestamp_utc=$(date -u +%Y%m%dT%H%M%SZ)"
    } >"$outfile"
  fi
  sync_path "$outfile"
}

refresh_live_logs_once() {
  local sys_root="$1"
  refresh_journal_once "$sys_root"
  refresh_dmesg_once "$sys_root"
  refresh_syslog_once "$sys_root"
}

stop_workers() {
  for pid_var in SNAPSHOT_PID TEMP_PID PUSH_PID LOG_SYNC_PID; do
    local pid="${!pid_var:-}"
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  wait || true
}

git_sync_once() {
  local now
  local staged_files
  local commit_output
  local push_output
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  run_git -C "$REPO_DIR" add --all -- "$SYS_ROOT_REL"
  staged_files="$(run_git -C "$REPO_DIR" diff --cached --name-only -- "$SYS_ROOT_REL")"
  if [[ -z "$staged_files" ]]; then
    return 0
  fi

  commit_output="$(run_git -C "$REPO_DIR" \
    -c user.name="$GIT_AUTHOR_NAME" \
    -c user.email="$GIT_AUTHOR_EMAIL" \
    commit -m "sys capture ${HOST_ID} ${BOOT_TS} ${now}" -- "$SYS_ROOT_REL" 2>&1)" || {
    log "git commit failed"
    log_multiline "git commit: " "$commit_output"
    return 1
  }

  if run_git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    push_output="$(run_git -C "$REPO_DIR" push origin "$REPO_BRANCH" 2>&1)" || {
      log "git push failed for origin/${REPO_BRANCH}"
      log_multiline "git push: " "$push_output"
      return 1
    }
  fi
}

main() {
  ensure_repo
  check_push_access

  local sys_root="${REPO_DIR}/${SYS_ROOT_REL}"
  local cleanup_done=0

  cleanup() {
    [[ "$cleanup_done" -eq 1 ]] && return 0
    cleanup_done=1
    log "stopping"
    git_sync_once || true
    stop_workers
  }

  prepare_sys_tree "$sys_root"
  trap cleanup EXIT INT TERM

  snapshot_once "$sys_root"
  capture_temperature_once "$sys_root"
  capture_hw_once "$sys_root"
  refresh_live_logs_once "$sys_root"

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
      refresh_live_logs_once "$sys_root"
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
SCRIPT_DIR="$(script_dir)"
REPO_DIR="$(discover_repo_dir "$SCRIPT_DIR")"
REPO_URL=""
REPO_BRANCH="$(current_repo_branch "$REPO_DIR")"
CMMHI_CMD=""
HOST_ID="$(hostname -s)"
SNAPSHOT_INTERVAL="1"
PUSH_INTERVAL="20"
STAGING_ROOT=""
START_SERVICE=1
STOP_SERVICE_MODE=0
INSTALL_SAMPLER=1
SAMPLER_URL="https://github.com/sqshq/sampler/releases/download/v1.1.0/sampler-1.1.0-linux-amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)
      REPO_DIR="${2:-}"
      shift 2
      ;;
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

[[ -n "$REPO_DIR" ]] || die "--repo-dir resolved to an empty path"
[[ -d "$REPO_DIR" ]] || die "repo dir does not exist: $REPO_DIR"
[[ -d "$REPO_DIR/.git" ]] || die "repo dir is not a git repo: $REPO_DIR"
REPO_DIR="$(cd -- "$REPO_DIR" && pwd -P)"

if [[ -z "$REPO_BRANCH" ]]; then
  REPO_BRANCH="$(current_repo_branch "$REPO_DIR")"
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
REPO_DIR=$(quote_env_value "$REPO_DIR")
REPO_URL=$(quote_env_value "$REPO_URL")
REPO_BRANCH=$(quote_env_value "$REPO_BRANCH")
SNAPSHOT_INTERVAL=$(quote_env_value "$SNAPSHOT_INTERVAL")
PUSH_INTERVAL=$(quote_env_value "$PUSH_INTERVAL")
GIT_AUTHOR_NAME=$(quote_env_value "crash-pusher")
GIT_AUTHOR_EMAIL=$(quote_env_value "crash-pusher@${HOST_ID}")
CMMHI_CMD=$(quote_env_value "$CMMHI_CMD")
CMMHI_TIMEOUT=$(quote_env_value "3")
EOF

for env_name in SSH_AUTH_SOCK GIT_ASKPASS SSH_ASKPASS DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_HANDLE ELECTRON_RUN_AS_NODE; do
  if [[ -n "${!env_name:-}" ]]; then
    printf '%s=%s\n' "$env_name" "$(quote_env_value "${!env_name}")" >>"$ENV_PATH"
  fi
done

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
echo "repo dir: $REPO_DIR"
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
