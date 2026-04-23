#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash install_crash_pusher.sh [options]

  bash install_crash_pusher.sh --search

  bash install_crash_pusher.sh --reg

  sudo bash install_crash_pusher.sh --stop

Options:
  --repo-dir DIR            Git repo that receives the sys updates. Default: git repo containing this script
  --repo-url URL            Optional override for the repo's origin remote. Default: keep existing origin
  --repo-branch BRANCH      Git branch to push to. Default: current branch of the cloned repo
  --cmmhi-cmd CMD           Temperature command to run every second. Default: leave unset unless provided or found via --search
  --host-id ID              Host label inside the repo. Default: hostname -s
  --snapshot-interval SEC   Seconds between system snapshots. Default: 1
  --push-interval SEC       Seconds between git commits/pushes after the initial push. Default: 20
  --search                  Search for cmmhi_rtm only. Updates /etc/default/crash-pusher if it already exists.
  --reg                     Register and restart the systemd service using the existing installed files.
  --staging-root DIR        Write files under DIR instead of /. Useful for local verification.
  --stop                    Stop and disable the crash-pusher service.
  --skip-sampler            Do not download / install sampler.
  --help                    Show this help.

Examples:
  bash install_crash_pusher.sh

  bash install_crash_pusher.sh --search

  bash install_crash_pusher.sh --reg

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

load_runtime_env() {
  ENV_FILE="${CRASH_PUSHER_ENV_FILE:-/etc/default/crash-pusher}"
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  HOST_ID="${HOST_ID:-$(hostname -s)}"
  HOST_ID="${CRASH_PUSHER_HOST_ID:-$HOST_ID}"
  REPO_DIR="${CRASH_PUSHER_REPO_DIR:-${REPO_DIR:-}}"
  REPO_URL="${CRASH_PUSHER_REPO_URL:-${REPO_URL:-}}"
  REPO_BRANCH="${CRASH_PUSHER_REPO_BRANCH:-${REPO_BRANCH:-}}"
  SNAPSHOT_INTERVAL="${CRASH_PUSHER_SNAPSHOT_INTERVAL:-${SNAPSHOT_INTERVAL:-1}}"
  PUSH_INTERVAL="${CRASH_PUSHER_PUSH_INTERVAL:-${PUSH_INTERVAL:-20}}"
  GIT_AUTHOR_NAME="${CRASH_PUSHER_GIT_AUTHOR_NAME:-${GIT_AUTHOR_NAME:-crash-pusher}}"
  GIT_AUTHOR_EMAIL="${CRASH_PUSHER_GIT_AUTHOR_EMAIL:-${GIT_AUTHOR_EMAIL:-crash-pusher@${HOST_ID}}}"
  CMMHI_CMD="${CRASH_PUSHER_CMMHI_CMD:-${CMMHI_CMD:-}}"
  CMMHI_TIMEOUT="${CRASH_PUSHER_CMMHI_TIMEOUT:-${CMMHI_TIMEOUT:-3}}"

  [[ -n "$REPO_DIR" ]] || die "REPO_DIR is not set in $ENV_FILE"

  REPO_OWNER_USER="$(stat -c %U "$REPO_DIR" 2>/dev/null || true)"
  REPO_OWNER_UID="$(stat -c %u "$REPO_DIR" 2>/dev/null || true)"

  BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"
  BOOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
  SYS_ROOT_REL="sys"
}

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

preserved_git_env_names() {
  cat <<'EOF'
SSH_AUTH_SOCK
GIT_ASKPASS
SSH_ASKPASS
DISPLAY
WAYLAND_DISPLAY
XAUTHORITY
DBUS_SESSION_BUS_ADDRESS
XDG_RUNTIME_DIR
VSCODE_GIT_ASKPASS_NODE
VSCODE_GIT_ASKPASS_MAIN
VSCODE_GIT_IPC_HANDLE
ELECTRON_RUN_AS_NODE
EOF
}

run_git() {
  local -a preserved_env=()
  local env_name

  while IFS= read -r env_name; do
    if [[ -n "${!env_name:-}" ]]; then
      preserved_env+=("${env_name}=${!env_name}")
    fi
  done < <(preserved_git_env_names)

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
  [[ -d "$REPO_DIR/.git" ]] || die "REPO_DIR is not a git repo: $REPO_DIR"

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

  if ! remote_url="$(run_git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"; then
    remote_url=""
  fi
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

emit_temperature_snapshot() {
  echo "timestamp_utc=$(date -u +%Y%m%dT%H%M%SZ)"

  echo
  echo "== cmmhi_rtm =="
  if [[ -n "$CMMHI_CMD" ]]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout "${CMMHI_TIMEOUT}" bash -lc "$CMMHI_CMD" 2>&1 || true
    else
      bash -lc "$CMMHI_CMD" 2>&1 || true
    fi
  else
    echo "cmmhi_rtm not configured"
  fi

  echo
  echo "== thermal zones =="
  for zone in /sys/class/thermal/thermal_zone*; do
    [[ -e "$zone" ]] || continue
    local zone_type zone_temp
    zone_type="$(cat "$zone/type" 2>/dev/null || echo unknown)"
    zone_temp="$(cat "$zone/temp" 2>/dev/null || echo unknown)"
    echo "${zone}: type=${zone_type} temp=${zone_temp}"
  done

  echo
  echo "== hwmon =="
  for sensor in /sys/class/hwmon/hwmon*/temp*_input; do
    [[ -e "$sensor" ]] || continue
    local label_file label
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
}

capture_temperature_once() {
  local sys_root="$1"
  local ts_file ts_iso
  ts_iso="$(date -u +%Y%m%dT%H%M%SZ)"
  ts_file="${sys_root}/temp/temperature.log"
  {
    echo
    echo "===== temperature timestamp_utc=${ts_iso} host=${HOST_ID} boot_id=${BOOT_ID} ====="
    emit_temperature_snapshot
  } >>"$ts_file" 2>&1 || true
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

acquire_git_sync_lock() {
  local lock_dir="${REPO_DIR}/.git/crash-pusher-sync.lock"
  local attempt=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 50 ]]; then
      log "git sync lock busy: ${lock_dir}"
      return 1
    fi
    sleep 0.2
  done

  GIT_SYNC_LOCK_DIR="$lock_dir"
}

release_git_sync_lock() {
  if [[ -n "${GIT_SYNC_LOCK_DIR:-}" && -d "$GIT_SYNC_LOCK_DIR" ]]; then
    rmdir "$GIT_SYNC_LOCK_DIR" 2>/dev/null || true
  fi
  GIT_SYNC_LOCK_DIR=""
}

stop_workers() {
  local pid_var pid
  for pid_var in SNAPSHOT_PID TEMP_PID PUSH_PID LOG_SYNC_PID; do
    pid="${!pid_var:-}"
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
  local add_output
  local rc=0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  acquire_git_sync_lock || return 1

  if ! add_output="$(run_git -C "$REPO_DIR" add --all -- "$SYS_ROOT_REL" 2>&1)"; then
    log "git add failed"
    log_multiline "git add: " "$add_output"
    rc=1
  elif ! staged_files="$(run_git -C "$REPO_DIR" diff --cached --name-only -- "$SYS_ROOT_REL" 2>/dev/null)"; then
    log "git staged diff failed"
    rc=1
  elif [[ -n "$staged_files" ]]; then
    commit_output="$(run_git -C "$REPO_DIR" \
      -c user.name="$GIT_AUTHOR_NAME" \
      -c user.email="$GIT_AUTHOR_EMAIL" \
      commit -m "sys capture ${HOST_ID} ${BOOT_TS} ${now}" -- "$SYS_ROOT_REL" 2>&1)" || {
      log "git commit failed"
      log_multiline "git commit: " "$commit_output"
      rc=1
    }

    if [[ "$rc" -eq 0 ]] && run_git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
      push_output="$(run_git -C "$REPO_DIR" push origin "$REPO_BRANCH" 2>&1)" || {
        log "git push failed for origin/${REPO_BRANCH}"
        log_multiline "git push: " "$push_output"
        rc=1
      }
    fi
  fi

  release_git_sync_lock
  return "$rc"
}

run_service_main() {
  load_runtime_env
  ensure_repo
  check_push_access

  local sys_root="${REPO_DIR}/${SYS_ROOT_REL}"
  local cleanup_done=0

  cleanup() {
    [[ "$cleanup_done" -eq 1 ]] && return 0
    cleanup_done=1
    log "stopping"
    stop_workers
    git_sync_once || true
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

  wait "$SNAPSHOT_PID" "$TEMP_PID" "$PUSH_PID" "$LOG_SYNC_PID"
}

capture_temp_main() {
  load_runtime_env
  emit_temperature_snapshot
}

write_service_file() {
  local dest="$1"
  local repo_dir="$2"
  local repo_script="${repo_dir}/install_crash_pusher.sh"
  cat >"$dest" <<EOF
[Unit]
Description=Crash log pusher
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=/etc/default/crash-pusher
WorkingDirectory=${repo_dir}
ExecStart=/bin/bash ${repo_script} --run-service
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

discover_repo_owner_user() {
  local repo_dir="$1"
  stat -c %U "$repo_dir" 2>/dev/null || true
}

discover_repo_owner_home() {
  local owner_user="$1"
  local passwd_line=""

  [[ -n "$owner_user" ]] || return 0

  passwd_line="$(getent passwd "$owner_user" 2>/dev/null || true)"
  if [[ -z "$passwd_line" ]]; then
    passwd_line="$(grep -E "^${owner_user}:" /etc/passwd 2>/dev/null | head -n 1 || true)"
  fi

  [[ -n "$passwd_line" ]] || return 0
  printf '%s\n' "$passwd_line" | cut -d: -f6
}

add_preserved_git_env() {
  local -n preserved_ref="$1"
  local env_name

  while IFS= read -r env_name; do
    if [[ -n "${!env_name:-}" ]]; then
      preserved_ref+=("${env_name}=${!env_name}")
    fi
  done < <(preserved_git_env_names)
}

run_repo_git() {
  local repo_owner_user="$1"
  shift
  local -a preserved_env=()

  add_preserved_git_env preserved_env

  if [[ -n "$repo_owner_user" && "$repo_owner_user" != "$(id -un)" ]] && command -v sudo >/dev/null 2>&1; then
    sudo -H -u "$repo_owner_user" env "${preserved_env[@]}" git "$@"
    return $?
  fi

  env "${preserved_env[@]}" git "$@"
}

bootstrap_repo_https_credentials() {
  local repo_dir="$1"
  local repo_branch="$2"
  local repo_owner_user="$3"
  local repo_owner_home="$4"
  local remote_url=""
  local cred_tmp=""

  if ! remote_url="$(run_repo_git "$repo_owner_user" -C "$repo_dir" remote get-url origin 2>/dev/null)"; then
    remote_url=""
  fi
  [[ "$remote_url" == https://github.com/* ]] || return 0

  if run_repo_git "$repo_owner_user" -C "$repo_dir" push --dry-run origin "$repo_branch" >/dev/null 2>&1; then
    return 0
  fi

  [[ -n "${GIT_ASKPASS:-}" ]] || return 0
  [[ -n "${VSCODE_GIT_ASKPASS_NODE:-}" ]] || return 0
  [[ -n "${VSCODE_GIT_ASKPASS_MAIN:-}" ]] || return 0
  [[ -n "${VSCODE_GIT_IPC_HANDLE:-}" ]] || return 0

  cred_tmp="$(mktemp)"
  chmod 0600 "$cred_tmp"

  if run_repo_git "$repo_owner_user" credential fill <<'EOF' >"$cred_tmp"
protocol=https
host=github.com

EOF
  then
    if grep -q '^password=' "$cred_tmp"; then
      run_repo_git "$repo_owner_user" config --global credential.helper store >/dev/null 2>&1 || true
      run_repo_git "$repo_owner_user" credential approve <"$cred_tmp" || true
      if [[ -n "$repo_owner_home" && -f "$repo_owner_home/.git-credentials" ]]; then
        chmod 0600 "$repo_owner_home/.git-credentials" || true
      fi
    fi
  fi

  rm -f "$cred_tmp"
}

upsert_env_setting() {
  local file="$1"
  local key="$2"
  local value="$3"
  local quoted_value
  local tmp_file

  quoted_value="$(quote_env_value "$value")"
  tmp_file="$(mktemp)"

  if [[ -f "$file" ]]; then
    awk -v key="$key" -v replacement="${key}=${quoted_value}" '
      BEGIN { updated = 0 }
      $0 ~ ("^" key "=") {
        if (updated == 0) {
          print replacement
          updated = 1
        }
        next
      }
      { print }
      END {
        if (updated == 0) {
          print replacement
        }
      }
    ' "$file" >"$tmp_file"
  else
    printf '%s=%s\n' "$key" "$quoted_value" >"$tmp_file"
  fi

  cat "$tmp_file" >"$file"
  rm -f "$tmp_file"
}

search_cmmhi_main() {
  local env_path
  local found_cmd="${CMMHI_CMD:-}"

  env_path="$(prefix_path /etc/default/crash-pusher)"

  if [[ -z "$found_cmd" ]]; then
    found_cmd="$(discover_cmmhi_cmd || true)"
  fi

  if [[ -n "$found_cmd" ]]; then
    printf 'cmmhi command: %s\n' "$found_cmd"
    if [[ -f "$env_path" ]]; then
      upsert_env_setting "$env_path" "CMMHI_CMD" "$found_cmd"
      upsert_env_setting "$env_path" "CMMHI_TIMEOUT" "3"
      chmod 0600 "$env_path" || true
      printf 'updated environment file: %s\n' "$env_path"
    else
      printf 'environment file not found: %s\n' "$env_path"
    fi
  else
    echo "cmmhi command: not found"
    if [[ -f "$env_path" ]]; then
      echo "existing environment file left unchanged"
    fi
  fi
}

register_service_main() {
  local env_path
  local service_path

  env_path="$(prefix_path /etc/default/crash-pusher)"
  service_path="$(prefix_path /etc/systemd/system/crash-pusher.service)"

  [[ -f "$env_path" ]] || die "environment file not found: $env_path; run the installer first"
  [[ -f "$service_path" ]] || die "service file not found: $service_path; run the installer first"

  if [[ -n "$STAGING_ROOT" ]]; then
    echo "staging mode: real register commands are:"
    echo "  systemctl daemon-reload"
    echo "  systemctl enable crash-pusher.service"
    echo "  systemctl restart crash-pusher.service"
    return 0
  fi

  require_cmd systemctl
  systemctl daemon-reload
  systemctl enable crash-pusher.service
  systemctl restart crash-pusher.service
  echo "crash-pusher.service enabled and restarted"
}

append_install_args() {
  local -n args_ref="$1"

  [[ "$SEARCH_MODE" -eq 1 ]] && args_ref+=(--search)
  [[ "$REGISTER_SERVICE_MODE" -eq 1 ]] && args_ref+=(--reg)
  [[ "$STOP_SERVICE_MODE" -eq 1 ]] && args_ref+=(--stop)
  [[ "$RUN_SERVICE_MODE" -eq 1 ]] && args_ref+=(--run-service)
  [[ "$CAPTURE_TEMP_MODE" -eq 1 ]] && args_ref+=(--capture-temp)

  if [[ "$RUN_SERVICE_MODE" -eq 1 || "$CAPTURE_TEMP_MODE" -eq 1 || "$STOP_SERVICE_MODE" -eq 1 ]]; then
    return 0
  fi

  [[ -n "${REPO_DIR:-}" ]] && args_ref+=(--repo-dir "$REPO_DIR")
  [[ -n "${REPO_URL:-}" ]] && args_ref+=(--repo-url "$REPO_URL")
  [[ -n "${REPO_BRANCH:-}" ]] && args_ref+=(--repo-branch "$REPO_BRANCH")
  [[ -n "${CMMHI_CMD:-}" ]] && args_ref+=(--cmmhi-cmd "$CMMHI_CMD")
  [[ -n "${HOST_ID:-}" ]] && args_ref+=(--host-id "$HOST_ID")
  [[ -n "${SNAPSHOT_INTERVAL:-}" ]] && args_ref+=(--snapshot-interval "$SNAPSHOT_INTERVAL")
  [[ -n "${PUSH_INTERVAL:-}" ]] && args_ref+=(--push-interval "$PUSH_INTERVAL")
  [[ -n "${STAGING_ROOT:-}" ]] && args_ref+=(--staging-root "$STAGING_ROOT")
  [[ "$INSTALL_SAMPLER" -eq 1 ]] || args_ref+=(--skip-sampler)
}

rerun_via_sudo() {
  local -a sudo_args=()
  local -a preserved_env_names=()
  local env_name
  local preserve_env_csv=""

  require_cmd sudo

  if [[ "$STOP_SERVICE_MODE" -eq 0 && "$SEARCH_MODE" -eq 0 && "$REGISTER_SERVICE_MODE" -eq 0 ]]; then
    [[ -n "$REPO_DIR" ]] || die "--repo-dir resolved to an empty path"
    [[ -d "$REPO_DIR" ]] || die "repo dir does not exist: $REPO_DIR"
    [[ -d "$REPO_DIR/.git" ]] || die "repo dir is not a git repo: $REPO_DIR"
    REPO_DIR="$(cd -- "$REPO_DIR" && pwd -P)"

    if [[ -z "$REPO_URL" ]]; then
      if ! REPO_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"; then
        REPO_URL=""
      fi
    fi

    if [[ -z "$REPO_BRANCH" ]]; then
      REPO_BRANCH="$(current_repo_branch "$REPO_DIR")"
    fi
  fi

  append_install_args sudo_args
  while IFS= read -r env_name; do
    if [[ -n "${!env_name:-}" ]]; then
      preserved_env_names+=("$env_name")
    fi
  done < <(preserved_git_env_names)

  if [[ "${#preserved_env_names[@]}" -gt 0 ]]; then
    preserve_env_csv="$(IFS=,; printf '%s' "${preserved_env_names[*]}")"
    exec sudo --preserve-env="$preserve_env_csv" bash -s -- "${sudo_args[@]}" <"$0"
  fi

  exec sudo bash -s -- "${sudo_args[@]}" <"$0"
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
SEARCH_MODE=0
REGISTER_SERVICE_MODE=0
STOP_SERVICE_MODE=0
RUN_SERVICE_MODE=0
CAPTURE_TEMP_MODE=0
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
    --search)
      SEARCH_MODE=1
      shift
      ;;
    --reg)
      REGISTER_SERVICE_MODE=1
      shift
      ;;
    --staging-root)
      STAGING_ROOT="${2:-}"
      shift 2
      ;;
    --run-service)
      RUN_SERVICE_MODE=1
      shift
      ;;
    --capture-temp)
      CAPTURE_TEMP_MODE=1
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

MODE_COUNT=$((SEARCH_MODE + REGISTER_SERVICE_MODE + STOP_SERVICE_MODE + RUN_SERVICE_MODE + CAPTURE_TEMP_MODE))
if [[ "$MODE_COUNT" -gt 1 ]]; then
  die "use only one of --search, --reg, --stop, --run-service, or --capture-temp at a time"
fi

if [[ "$RUN_SERVICE_MODE" -eq 1 ]]; then
  run_service_main
  exit 0
fi

if [[ "$CAPTURE_TEMP_MODE" -eq 1 ]]; then
  capture_temp_main
  exit 0
fi

if [[ -z "$STAGING_ROOT" ]] && [[ "$(id -u)" -ne "$ROOT_UID" ]]; then
  rerun_via_sudo
fi

if [[ "$SEARCH_MODE" -eq 1 ]]; then
  if [[ -n "$STAGING_ROOT" ]]; then
    mkdir -p "$STAGING_ROOT"
  fi
  search_cmmhi_main
  exit 0
fi

if [[ "$REGISTER_SERVICE_MODE" -eq 1 ]]; then
  if [[ -n "$STAGING_ROOT" ]]; then
    mkdir -p "$STAGING_ROOT"
  fi
  register_service_main
  exit 0
fi

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

if [[ -n "$STAGING_ROOT" ]]; then
  mkdir -p "$STAGING_ROOT"
else
  STAGING_ROOT=""
fi

[[ -n "$REPO_DIR" ]] || die "--repo-dir resolved to an empty path"
[[ -d "$REPO_DIR" ]] || die "repo dir does not exist: $REPO_DIR"
[[ -d "$REPO_DIR/.git" ]] || die "repo dir is not a git repo: $REPO_DIR"
REPO_DIR="$(cd -- "$REPO_DIR" && pwd -P)"
REPO_OWNER_USER="$(discover_repo_owner_user "$REPO_DIR")"
REPO_OWNER_HOME="$(discover_repo_owner_home "$REPO_OWNER_USER")"

if [[ -z "$REPO_BRANCH" ]]; then
  REPO_BRANCH="$(current_repo_branch "$REPO_DIR")"
fi

BIN_DIR="$(prefix_path /usr/local/bin)"
ETC_DEFAULT_DIR="$(prefix_path /etc/default)"
SYSTEMD_DIR="$(prefix_path /etc/systemd/system)"

install -d -m 0755 "$BIN_DIR" "$ETC_DEFAULT_DIR" "$SYSTEMD_DIR"

REPO_SCRIPT_PATH="${REPO_DIR}/install_crash_pusher.sh"
ENV_PATH="${ETC_DEFAULT_DIR}/crash-pusher"
SERVICE_PATH="${SYSTEMD_DIR}/crash-pusher.service"
SAMPLER_PATH="${BIN_DIR}/sampler"

[[ -f "$REPO_SCRIPT_PATH" ]] || die "repo script not found: $REPO_SCRIPT_PATH"
write_service_file "$SERVICE_PATH" "$REPO_DIR"

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

while IFS= read -r env_name; do
  if [[ -n "${!env_name:-}" ]]; then
    printf '%s=%s\n' "$env_name" "$(quote_env_value "${!env_name}")" >>"$ENV_PATH"
  fi
done < <(preserved_git_env_names)

chmod 0600 "$ENV_PATH"

bootstrap_repo_https_credentials "$REPO_DIR" "$REPO_BRANCH" "$REPO_OWNER_USER" "$REPO_OWNER_HOME"

if [[ "$INSTALL_SAMPLER" -eq 1 ]]; then
  curl -fsSL "$SAMPLER_URL" -o "$SAMPLER_PATH"
  chmod 0755 "$SAMPLER_PATH"
fi

ensure_hw_inventory_tools

if [[ -n "$STAGING_ROOT" ]]; then
  echo "staging install completed at $STAGING_ROOT"
  echo "manual service test example:"
  echo "  CRASH_PUSHER_ENV_FILE=$ENV_PATH /bin/bash $REPO_SCRIPT_PATH --run-service"
else
  register_service_main
fi

echo "installer completed"
echo "environment file: $ENV_PATH"
echo "service file: $SERVICE_PATH"
echo "service entrypoint: $REPO_SCRIPT_PATH --run-service"
echo "repo dir: $REPO_DIR"
echo "service status: enabled and restarted"
echo "to re-register later: bash install_crash_pusher.sh --reg"
echo "to stop later: bash install_crash_pusher.sh --stop"
echo "manual stop command: sudo systemctl disable --now crash-pusher.service"
if [[ -n "$CMMHI_CMD" ]]; then
  echo "cmmhi command: $CMMHI_CMD"
else
  echo "cmmhi command: not configured; run: bash install_crash_pusher.sh --search"
fi
if [[ "$INSTALL_SAMPLER" -eq 1 ]]; then
  echo "sampler: $SAMPLER_PATH"
fi
