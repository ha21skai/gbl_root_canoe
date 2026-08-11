#!/system/bin/sh
# Retain BL version after system update
if [ -z "$MODDIR" ]; then
  MODDIR=$(CDPATH= cd -- "$(dirname "$0")/.." 2>/dev/null && pwd)
fi
if [ -z "$MODDIR" ]; then
  echo 'ERROR=MODDIR detection failed' >&2
  exit 1
fi
RUNTIME_DIR="$MODDIR/tmp"
BY_NAME_DIR="/dev/block/by-name"
IMAGE_NAMES="abl"
LOG_FILE="$RUNTIME_DIR/flash.log"
STATE_FILE="$RUNTIME_DIR/state"
MESSAGE_FILE="$RUNTIME_DIR/message"
UPDATED_FILE="$RUNTIME_DIR/updated"
PID_FILE="$RUNTIME_DIR/flash.pid"
LOCK_DIR="$RUNTIME_DIR/flash.lock"

export PATH=/data/adb/ksu/bin:/system/bin:/system/xbin:$PATH

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
read_line() { [ -f "$1" ] && head -n 1 "$1"; }
emit() { printf '%s' "$1" | tr '\n' '\t'; }

ensure_runtime() {
  mkdir -p "$RUNTIME_DIR"
  [ -f "$LOG_FILE" ]     || : > "$LOG_FILE"
  [ -f "$STATE_FILE" ]   || printf '%s\n' 'idle' > "$STATE_FILE"
  [ -f "$MESSAGE_FILE" ] || printf '%s\n' 'Awaiting user action...' > "$MESSAGE_FILE"
  [ -f "$UPDATED_FILE" ] || timestamp > "$UPDATED_FILE"
}

write_state() {
  ensure_runtime
  printf '%s\n' "$1" > "$STATE_FILE"
  printf '%s\n' "$2" > "$MESSAGE_FILE"
  timestamp > "$UPDATED_FILE"
}

write_log() {
  ensure_runtime
  printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

detect_current_slot() {
  case "$(getprop ro.boot.slot_suffix 2>/dev/null)" in
    _a) printf '%s\n' '_a' ;;
    _b) printf '%s\n' '_b' ;;
    *)  return 1 ;;
  esac
}

other_slot() {
  case "$1" in
    _a) printf '%s\n' '_b' ;;
    _b) printf '%s\n' '_a' ;;
    *)  return 1 ;;
  esac
}

partition_path() { printf '%s\n' "$BY_NAME_DIR/${1}${2}"; }

current_pid() {
  if [ -f "$PID_FILE" ]; then
    pid=$(tr -d '[:space:]' < "$PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"; return 0
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}
# extractfv and patch_abl from abl_dest
# 0 success, 1 failed 2 new ABL version with GBL vulnerability detected, skipping BL flash to preserve BL version
# $1: abl partition path, $2: install_superfastboot (optional, "with-superfastboot" to enable), $3: debug_mode (optional, "debug" to skip flash)
patch_efisp() {
  install_superfastboot="${2:-no-superfastboot}"
  debug_mode="${3:-no-debug}"
  rm "$RUNTIME_DIR/patched.efi" 2>/dev/null || true
  rm "$RUNTIME_DIR/patch.log" 2>/dev/null || true
  rm "$RUNTIME_DIR/LinuxLoader.efi" 2>/dev/null || true
  $MODDIR/bin/extractfv -o "$RUNTIME_DIR" -v "$1" >> "$LOG_FILE" 2>&1
  #patch abl
  $MODDIR/bin/patch_abl "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi" >> "$RUNTIME_DIR/patch.log" 2>&1
  cat "$RUNTIME_DIR/patch.log" >> "$LOG_FILE"
  if [ ! -f "$RUNTIME_DIR/patched.efi" ]; then
    write_log 'Failed to apply the patch'
    return 1
  fi

  # If superfastboot is enabled, inject loader.elf
  if [ "$install_superfastboot" = "with-superfastboot" ]; then
    write_log 'Injecting superfastboot loader...'
    if [ ! -f "$MODDIR/loader.elf" ]; then
      write_log 'loader.elf does not exist; unable to install superfastboot'
      return 1
    fi
    # Inject loader into patched.efi (outputs DLL format)
    $MODDIR/bin/elf_inject "$MODDIR/loader.elf" "$RUNTIME_DIR/patched.efi" "$RUNTIME_DIR/injected.dll" >> "$LOG_FILE" 2>&1
    if [ ! -f "$RUNTIME_DIR/injected.dll" ]; then
      write_log 'Failed to execute elf_inject'
      return 1
    fi
    # Convert DLL back to EFI
    $MODDIR/bin/GenFw -e UEFI_APPLICATION -o "$RUNTIME_DIR/patched.efi" "$RUNTIME_DIR/injected.dll" >> "$LOG_FILE" 2>&1
    if [ ! -f "$RUNTIME_DIR/patched.efi" ]; then
      write_log 'GenFw conversion failed'
      return 1
    fi
    write_log 'superfastboot loader injection completed'
  fi

  # Skip flash in debug mode
  if [ "$debug_mode" = "debug" ]; then
    write_log "Debug mode: Skipped flashing the efisp partition. The file has been saved to $RUNTIME_DIR/patched.efi"
    return 0
  fi

  #flash
  if ! blockdev --setrw "/dev/block/by-name/efisp" >> "$LOG_FILE" 2>&1; then
    write_log 'Failed to set the efisp partition as writable'
    return 1
  fi
  if ! dd if="$RUNTIME_DIR/patched.efi" of=/dev/block/by-name/efisp bs=4M conv=fsync >> "$LOG_FILE" 2>&1; then
    write_log 'Failed to flash efisp using dd'
    return 1
  fi
  sync
  write_log "Flashing of the efisp partition complete"
  #Checking if the patch log contains "Warning: Failed to patch ABL GBL\n". If not present, the new ABL version contains the GBL vulnerability; returning a dummy failure to bypass subsequent BL flashing
  if ! grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
    write_log "New ABL version detected with GBL vulnerability present. Skipping subsequent BL flashing to retain the current BL version."
    return 2
  fi
  return 0
}

# detect ABL GBL vulnerability without flashing efisp
# 0 vulnerable (should skip BL flash), 1 detect failed, 2 not vulnerable
detect_gbl_vulnerability() {
  rm "$RUNTIME_DIR/patched.efi" 2>/dev/null || true
  rm "$RUNTIME_DIR/patch.log" 2>/dev/null || true
  rm "$RUNTIME_DIR/LinuxLoader.efi" 2>/dev/null || true
  $MODDIR/bin/extractfv -o "$RUNTIME_DIR" -v "$1" >> "$LOG_FILE" 2>&1
  $MODDIR/bin/patch_abl "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi" >> "$RUNTIME_DIR/patch.log" 2>&1
  cat "$RUNTIME_DIR/patch.log" >> "$LOG_FILE"
  if [ ! -f "$RUNTIME_DIR/patched.efi" ]; then
    write_log 'Vulnerability detection failed: Patch file was not generated'
    return 1
  fi
  if ! grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
    write_log 'New ABL version detected with GBL vulnerability present. Skipping subsequent BL flashing'
    return 0
  fi
  write_log 'No GBL vulnerability detected. Proceeding with subsequent BL flashing'
  return 2
}

cleanup_lock() { rm -rf "$LOCK_DIR"; rm -f "$PID_FILE";  }

print_status() {
  ensure_runtime
  current_slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
  case "$current_slot" in _a|_b) ;; *) current_slot='' ;; esac
  target_slot=''
  case "$current_slot" in _a) target_slot='_b' ;; _b) target_slot='_a' ;; esac

  running='0'; pid=''
  if [ -f "$PID_FILE" ]; then
    pid=$(tr -d '[:space:]' < "$PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      running='1'
    else
      pid=''; rm -f "$PID_FILE"
    fi
  fi


  _state=''; [ -f "$STATE_FILE" ] && read -r _state < "$STATE_FILE"
  _msg=''; [ -f "$MESSAGE_FILE" ] && read -r _msg < "$MESSAGE_FILE"
  _upd=''; [ -f "$UPDATED_FILE" ] && read -r _upd < "$UPDATED_FILE"

  _out="CURRENT_SLOT=${current_slot}
TARGET_SLOT=${target_slot}
RUNNING=${running}
PID=${pid}
STATE=${_state}
MESSAGE=${_msg}
UPDATED_AT=${_upd}"

  emit "$_out"
}

run_flash() {
  update_efisp="${1:-skip-efisp}"
  install_superfastboot="no-superfastboot"
  debug_mode="no-debug"
  # Parse mode
  case "$update_efisp" in
    "update-efisp-with-superfastboot")
      update_efisp="update-efisp"
      install_superfastboot="with-superfastboot"
      ;;
    "debug")
      debug_mode="debug"
      update_efisp="skip-efisp"
      ;;
    "debug-with-superfastboot")
      debug_mode="debug"
      update_efisp="update-efisp"
      install_superfastboot="with-superfastboot"
      ;;
  esac

  ensure_runtime
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    write_log 'Flashing task is already running. Duplicate execution rejected.'
    exit 1
  fi
  printf '%s\n' "$$" > "$PID_FILE"
  trap cleanup_lock EXIT INT TERM HUP
  : > "$LOG_FILE"

  current_slot=$(detect_current_slot 2>/dev/null || true)
  if [ -z "$current_slot" ]; then
    write_state 'error' 'Failed to identify current slot'; write_log 'Failed to identify current slot'; exit 1
  fi
  target_slot=$(other_slot "$current_slot" 2>/dev/null || true)
  if [ -z "$target_slot" ]; then
    write_state 'error' 'Failed to calculate target slot'; write_log 'Failed to calculate target slot'; exit 1
  fi

  write_state 'running' "Flashing image to slot... $target_slot"
  write_log "Current slot: $current_slot  Target slot: $target_slot"

  # Debug mode: process but don't flash
  if [ "$debug_mode" = "debug" ]; then
    write_log "Debug mode: Process only, do not flash"
    abl_part=$(partition_path abl "$target_slot")
    if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
      patch_efisp "$abl_part" "$install_superfastboot" "$debug_mode"
      ret=$?
      if [ $ret -eq 0 ]; then
        write_state 'success' "Debugging complete. File saved to $RUNTIME_DIR"
        write_log "Debugging complete. Generated file: $RUNTIME_DIR/patched.efi"
      else
     write_state 'error' 'Error occurred during debugging'
        write_log 'Debugging failed. Please check the log.'
      fi
    else
      write_log 'Debug mode: efisp update not checked; extracting ABL only'
      rm "$RUNTIME_DIR/LinuxLoader.efi" 2>/dev/null || true
      $MODDIR/bin/extractfv -o "$RUNTIME_DIR" -v "$abl_part" >> "$LOG_FILE" 2>&1
      if [ -f "$RUNTIME_DIR/LinuxLoader.efi" ]; then
        write_state 'success' "Debugging complete. ABL extracted to $RUNTIME_DIR/LinuxLoader.efi"
        write_log "Debugging complete. Extracted ABL: $RUNTIME_DIR/LinuxLoader.efi"
      else
        write_state 'error' 'Failed to extract ABL'
      fi
    fi
    exit 0
  fi

  efisp_failed='0'
  abl_part=$(partition_path abl "$target_slot")

  if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
    #patch abl and flash efisp first, since it's the only one that can brick the device if something goes wrong
    #0 success, 1 failed, 2 new ABL version with GBL vulnerability detected
    patch_efisp "$abl_part" "$install_superfastboot" "$debug_mode"
    ret=$?
    case $ret in
      0) ;; # 成功，继续
       1) efisp_failed='1'
         write_state 'running' 'Failed to flash efisp partition. Continuing BL flashing to retain the old version'
         write_log 'Warning: Failed to apply new ABL patch. Continuing BL flashing to retain BL version for loading old efisp'
         write_log 'Theoretically, retaining the BL version can boot successfully, but unknown risks cannot be ruled out. Please upload the patch log for analysis'
         ;;
      2) write_state 'success' 'efisp partition flashing completed, but BL flashing was skipped to retain the BL version'
         write_log 'efisp partition flashing completed, but BL flashing was skipped (GBL vulnerability detected)'
         exit 0 ;;
      *) write_state 'error' 'Unknown error'
         exit 1 ;;
    esac
  else
    write_log 'efisp update not checked; skipping efisp partition operations'
      detect_gbl_vulnerability "$abl_part"
      ret=$?
      case $ret in
        0) write_state 'success' 'GBL vulnerability detected; skipped BL flashing'
           write_log 'efisp not updated and GBL vulnerability detected; skipped BL flashing'
           exit 0 ;;
        1) write_log 'Vulnerability detection failed; continuing BL flashing process' ;;
        2) ;;
        *) write_log 'Warning: Unknown detection result. Continuing BL flashing process' ;;
      esac
  fi

  for name in $IMAGE_NAMES; do
    part=$(partition_path "$name" "$target_slot")
    srcpart=$(partition_path "$name" "$current_slot")

    write_log "blockdev --setrw $part"
    if ! blockdev --setrw "$part" >> "$LOG_FILE" 2>&1; then
      write_state 'error' "Failed to set partition $name as writable"; exit 1
    fi
    write_log "Flashing $name -> $part"
    if ! dd if="$srcpart" of="$part" bs=4M conv=fsync >> "$LOG_FILE" 2>&1; then
      write_state 'error' "Partition $name flashing failed"; exit 1
    fi
    sync
    write_log "$name complete"
  done

  if [ "$efisp_failed" = '1' ]; then
    write_state 'warning' "BL flashing completed, but efisp was not updated"
    write_log 'BL image flashing completed, but efisp was not updated'
  elif [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
    write_state 'success' "All flashing completed (including efisp)"
    write_log 'All images and efisp flashing completed'
  else
    write_state 'success' "All flashing completed (efisp not updated)"
    write_log 'All images flashing completed (efisp not updated)'
  fi
}

start_flash() {
  update_efisp="${1:-skip-efisp}"
  ensure_runtime
  if pid=$(current_pid 2>/dev/null); then
    emit "ALREADY_RUNNING=${pid}"; return 0
  fi
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$0" flash "$update_efisp" >/dev/null 2>&1 &
  else
    sh "$0" flash "$update_efisp" </dev/null >/dev/null 2>&1 &
  fi
  sleep 1
  if pid=$(current_pid 2>/dev/null); then
    emit "STARTED=1
PID=${pid}"
  else
    _st=''; [ -f "$STATE_FILE" ] && read -r _st < "$STATE_FILE"
    case "$_st" in
      success|error|warning) emit "FINISHED=${_st}" ;;
      *) emit 'STARTED=0' ;;
    esac
  fi
}

print_log() { ensure_runtime; tr '\n' '\t' < "$LOG_FILE"; }
tail_log()  { ensure_runtime; tail -n "${1:-200}" "$LOG_FILE" | tr '\n' '\t'; }

clear_log() {
  ensure_runtime
  if current_pid >/dev/null 2>&1; then emit 'BUSY=1'; return 1; fi
  : > "$LOG_FILE"
  write_state 'idle' 'Log cleared'
  emit 'CLEARED=1'
}

case "$1" in
  status)    print_status ;;
  flash)     run_flash "$2" ;;
  start)     start_flash "$2" ;;
  log)       print_log ;;
  tail)      tail_log "$2" ;;
  clear-log) clear_log ;;
  *)         printf 'Usage: %s {status|flash|start|log|tail [lines]|clear-log}\n' "$0" >&2; exit 1 ;;
esac
