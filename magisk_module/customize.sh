#!/system/bin/sh

ui_print "- Verifying device model"
_model=$(getprop ro.product.model 2>/dev/null)
_name=$(getprop ro.product.name 2>/dev/null)
_incr=$(getprop ro.build.version.incremental 2>/dev/null)
ui_print "- Device verified: $_model / $_name / $_incr"
ui_print "- Setting permissions"
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
set_perm "$MODPATH/module.prop" 0 0 0644
set_perm "$MODPATH/skip_mount" 0 0 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

detect_current_slot() {
  case "$(getprop ro.boot.slot_suffix 2>/dev/null)" in
    _a) printf '%s\n' '_a' ;;
    _b) printf '%s\n' '_b' ;;
    *)  return 1 ;;
  esac
}
BY_NAME_DIR="/dev/block/by-name"
RUNTIME_DIR="$MODPATH/tmp"
mkdir -p "$RUNTIME_DIR"
partition_path() { printf '%s\n' "$BY_NAME_DIR/${1}${2}"; }
#install efisp
ui_print "Ensure that your kernel does not have Baseband Guard, and that your device's bootloader is unlocked."
ui_print "Ensure that your device is powered by Snapdragon 8 Gen 5 / Snapdragon 8 Elite Gen 5"
ui_print "Checking for vulnerabilities..."
current_slot=$(detect_current_slot 2>/dev/null)
ui_print "Please select whether this is your first time installing the fake lock."
ui_print "Volume Up for Yes (Clean install, requires data format)"
ui_print "Volume Down for No (Recommended if you have previously installed the fake lock, or if you just completed the first-time installation and data format)"
ui_print "If you select "Yes", the patched efisp will be installed and the system will reboot into Recovery to perform a format. After formatting, please install this module again to complete the installation, and select "No" at that point"
ui_print "If you select "No", the OTA update patch will be installed. To retain your BL version, you must open this module to install the patch after every OTA update. Once the installation is complete, simply reboot the system"
while true; do #Looping and waiting for user key selection: Volume Up for Yes, Volume Down for No
  keyevent=$(timeout 0.5 getevent -l 2>/dev/null)
  if echo "$keyevent" | grep -q "KEY_VOLUMEUP"; then
    ui_print "Selected "Yes". Installing the patched efisp..."
    if [ -z "$current_slot" ]; then
      ui_print "Failed to identify the current slot. Installation aborted"
      abort "cannot detect current slot"
    fi
    abl_part=$(partition_path abl "$current_slot")
    $MODPATH/bin/extractfv -o "$MODPATH/tmp" -v "$abl_part" >> "$MODPATH/tmp/extract.log" 2>&1
    $MODPATH/bin/patch_abl "$MODPATH/tmp/LinuxLoader.efi" "$MODPATH/tmp/patched.efi" >> "$MODPATH/tmp/patch.log" 2>&1
    if [ ! -f "$MODPATH/tmp/patched.efi" ]; then
      ui_print "Failed to apply the patch. Installation aborted"
      abort "patch failed"
    fi
    if grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
      ui_print "GBL vulnerability not found. Installation failed and aborted"
      abort "no exploit"
    fi
    if ! blockdev --setrw "/dev/block/by-name/efisp" >> "$MODPATH/tmp/flash.log" 2>&1; then
      ui_print "Failed to set the efisp partition as writable. Installation aborted"
      abort "setrw failed"
    fi
    if ! dd if="$MODPATH/tmp/patched.efi" of=/dev/block/by-name/efisp bs=4M conv=fsync >> "$MODPATH/tmp/flash.log" 2>&1; then
      ui_print "Failed to flash the efisp partition. Installation aborted"
      abort "flash failed"
    fi
    sync
    ui_print "Installation complete. Please reboot into Recovery to format. After formatting, install this module once more to complete the setup, selecting "No" this time"
    rm -rf "$RUNTIME_DIR"
    break
  elif echo "$keyevent" | grep -q "KEY_VOLUMEDOWN"; then
    ui_print "Selected "No". Installing the OTA update module..."
    ui_print "Installation complete. Simply reboot the system"
    rm -rf "$RUNTIME_DIR"
    break
  fi
done

