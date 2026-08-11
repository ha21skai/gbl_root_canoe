#!/system/bin/sh

MODDIR=${0%/*}

rm -rf "$MODDIR/tmp"
ui_print "Uninstallation complete. Only the OTA update auxiliary tool has been removed. Please uninstall the mock re-lock manually, as it requires a data wipe."