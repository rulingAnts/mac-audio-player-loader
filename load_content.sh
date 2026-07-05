#!/bin/bash
#
# Audio Player Loader — bulk-erase external USB disks and load audio content onto
# player devices (MegaVoice and similar players). See TECHNICAL.html for full specs.
#
# Copyright (C) 2026 Seth Johnston
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. Distributed WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Affero General Public License <https://www.gnu.org/licenses/> for details.
# The full license text ships beside this script as LICENSE.txt.

# If invoked with sh/zsh/dash by mistake, restart under real bash.
# NB: macOS /bin/sh IS bash but in POSIX mode (BASH_VERSION set!), so we
# must also check POSIXLY_CORRECT or process substitution below breaks.
# The re-exec strips POSIXLY_CORRECT from the environment (env -u): if the
# caller had EXPORTED it, a plain `exec /bin/bash` would inherit it, re-enter
# POSIX mode, and exec again — an infinite loop. ${VAR+x} tests set-ness, since
# even an empty POSIXLY_CORRECT puts bash in POSIX mode.
[ -n "$BASH_VERSION" ] && [ -z "${POSIXLY_CORRECT+x}" ] || exec /usr/bin/env -u POSIXLY_CORRECT /bin/bash "$0" "$@"

# One-pass loading for all attached USB devices, in parallel:
#   1) GUI disk picker (whole DISKS, all their volumes shown) with a
#      final erase/keep confirmation
#   2) fresh full-size MBR + FAT32 partition per disk (verified)
#   3) content copied in name order (FAT dir order == play order)
#   4) macOS junk scrubbed from the volume, junk check, per-device eject
#
# This script lives INSIDE the content folder (HTG-style, like HTGv4.CMD):
# it copies everything in its own directory to each device, except itself
# and its helper files (.app / .zip / .cmd / .txt / .md / .html and the
# images/ folder — see RSYNC_EXCLUDES below for the authoritative list).
#
# Junk handling, by mechanism:
#   .DS_Store        -> Finder's .DS_Store-on-USB writing is suppressed for the
#                       run (the setting is RESTORED afterwards) so none lands
#                       ahead of the content; also excluded and scrubbed as well
#   ._* AppleDouble  -> CANNOT be prevented on modern macOS (synthesized on
#                       FAT for any file carrying the un-clearable
#                       com.apple.provenance xattr), so they are SCRUBBED
#                       from the volume after the copy
#   .Spotlight-V100  -> created by mdutil, SIP-protected (unremovable) but
#                       tiny + harmless on the players — left as-is
#   .fseventsd       -> off-switch is an empty no_log file inside it; tiny,
#                       unavoidable, harmless — left as-is
# Net remnant on each device: .Spotlight-V100/ and .fseventsd/no_log only.

# ===========================================================================
# HOW THIS SCRIPT IS ORGANISED  (read this first if you're modifying it)
#
# It runs top-to-bottom as a sequence of phases. Two phases (erase and copy)
# fan out across background subshells — one per device — for speed:
#
#   CONFIGURATION .......... tunable variables (just below)
#   HELPER FUNCTIONS ....... shell functions used later (notify, blink, etc.)
#   MAIN FLOW STARTS HERE .. everything from the label prompt onward:
#     · Label prompt ....... ask for the FAT volume label
#     · Source resolution .. find (and protect) the disk holding the content
#     · Enumerate .......... list candidate external disks -> arrays (below)
#     · Pick & confirm ..... GUI (or text) selection + erase/keep confirmation
#     · Erase   (parallel) . per disk: re-verify identity, then eraseDisk
#     · Prepare ............ mount each fresh volume; verify it is ours
#     · Copy    (parallel) . per device: rsync, scrub macOS junk, eject
#     · Progress ........... main loop polls status files -> progress bar
#     · Results ............ bucket devices, relabel failures, print summary
#     · Run again .......... offer to re-exec for the next batch
#
# INTER-PROCESS COMMUNICATION — background subshells never share variables
# with the parent. Each writes ONE small status file into $STATUS_DIR (a
# mktemp dir), and the parent polls those files. That is the ONLY channel:
#     $STATUS_DIR/diskN            first word is a CODE:  OK | CHECK | REDO
#     $STATUS_DIR/diskN.erased     marker written when eraseDisk succeeded
#     $STATUS_DIR/diskN.notloaded  device never reached the copy phase
#     $STATUS_DIR/diskN.err        captured rsync stderr (for the message)
#     $STATUS_DIR/.blink           flag file; blink loops run while it exists
# $STATUS_DIR is deleted by an EXIT trap (and by hand before any re-exec).
#
# KEY ARRAYS (paired arrays stay index-aligned):
#     devices[] dev_bytes[] labels[]   candidate disks   (enumerate phase)
#     copy_devs[] mps[] pids[]         devices copied to (copy phase)
#     last_used[] last_move[]          per-device progress bookkeeping
#
# SAFETY MODEL — every destructive or writing command is immediately preceded
# by a device-identity re-check, so a device that was unplugged or whose diskN
# number got reused can never cause the wrong disk to be erased or the internal
# drive to be written to. The three commands that touch disks are eraseDisk,
# rsync, and the blink dd; each is guarded. Full rationale in TECHNICAL.html §5.
# ===========================================================================


# ============================ CONFIGURATION ================================
# App name shown in dialogs / notifications / the Terminal title. Generic on
# purpose — this loader works with any audio player (MegaVoice, etc.) as long as
# the source folder has the right file/folder structure. Change it here only.
APP_TITLE="Audio Player Loader"
DEFAULT_LABEL="PLAYER"
REDO_LABEL="REDO"          # failed devices are renamed to this so they are
                          # obvious on the desktop and in the next run's list
STALL_LIMIT=300           # seconds with zero write progress before a device is declared dead
COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo "This Mac")

# GUI available unless we are in an SSH session with no local display
use_gui=0
[ -z "$SSH_CONNECTION" ] && use_gui=1

# --- Colors: only when stdout is a real terminal, and honor NO_COLOR ---
# (kept OUT of the status files themselves, so parsing stays clean)
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  cR=$'\033[0m'; cB=$'\033[1m'; cDIM=$'\033[2m'
  cGRN=$'\033[32m'; cRED=$'\033[31m'; cYEL=$'\033[33m'; cCYN=$'\033[36m'
else
  cR=; cB=; cDIM=; cGRN=; cRED=; cYEL=; cCYN=
fi

# ========================= HELPER FUNCTIONS ================================
# Defined here, called later from the MAIN FLOW. Nothing below executes until
# it is invoked, EXCEPT the color block above and these definitions.

# --- Small GUI helpers (best-effort; no-ops without a GUI) -------------
# Terminal output is the record; these only add attention-grabbers for an
# operator who has walked away from the screen during a long copy. Each uses
# osascript's `on run {..}` form so arguments pass as a safe argv (no risk of
# a device/volume name breaking the AppleScript quoting).
notify() {  # $1 title, $2 message -> non-blocking Notification Center banner
  [ "$use_gui" -eq 1 ] || return 0
  osascript -e "on run {t, m}" -e "display notification m with title t sound name \"Glass\"" \
    -e "end run" "$1" "$2" >/dev/null 2>&1
}
gui_alert() {  # $1 title, $2 message -> blocking critical alert (hard to miss)
  [ "$use_gui" -eq 1 ] || return 0
  osascript -e "on run {t, m}" -e "display alert t message m as critical" \
    -e "end run" "$1" "$2" >/dev/null 2>&1
}
set_title() {  # $1 text -> update the Terminal tab/title (visible when backgrounded)
  printf '\033]0;%s\007' "$1"
}

# --- Cleanup / restore-on-exit -----------------------------------------
# Finder writes a .DS_Store to any mounted USB volume, and it can land BEFORE
# the content (taking an early FAT directory slot). The scrub removes it and the
# final content order is still correct — but as a belt-and-suspenders for minimal
# player firmware we suppress that Finder behaviour for the DURATION of a run via
# the machine-wide DSDontWriteUSBStores default, then put the setting back so we
# never leave someone's Mac changed. $DSUSB_ORIG records the pre-run value:
# "1"=was on, "0"=was off, ""=key absent; UNSET means we never changed it. It is
# exported so the true original survives the run-again exec (read once, on run 1).
restore_dsusb() {
  [ -n "${DSUSB_ORIG+x}" ] || return 0        # never changed it -> nothing to undo
  case "$DSUSB_ORIG" in
    1) defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true ;;
    0) defaults write com.apple.desktopservices DSDontWriteUSBStores -bool false ;;
    *) defaults delete com.apple.desktopservices DSDontWriteUSBStores 2>/dev/null ;;  # was absent
  esac
}
# Single EXIT handler: stop any LED-blink loops, remove the scratch dir, and
# restore the Mac-side setting. Runs on Done, on the dead-end exits, and on
# Ctrl-C / HUP — but NOT across the run-again `exec` (exec does not fire EXIT
# traps), so the setting stays off between batches and is restored only when
# the whole session finally ends (after every device is written and ejected).
# stop_blink comes FIRST so no blinker can outlive the script and keep writing
# to a device after we are gone.
cleanup() {
  stop_blink
  [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
  restore_dsusb
}

# --- LED blink for failed devices --------------------------------------
# Blink a device's LED by WRITING + sync in a loop (the only way to force real
# device I/O without sudo: raw reads need root; repeat file reads are cached).
# CRITICAL: the dialog tells the operator to unplug devices WHILE they blink,
# and a hard-yanked USB volume can leave /Volumes/<name> behind as a plain
# folder on the BOOT disk — so re-verify the target is still THIS external
# device before EVERY write (mirrors ok_mount in the copy phase). Otherwise we
# would pour data onto the internal drive.
BLINK_PIDS=()
BLINK_FLAG=""
blink_one() {  # $1 = diskN, $2 = mount point, $3 = flag file
  local dev=$1 mp=$2 flag=$3 tmp="$2/.audioloader_blink"
  # Two stop conditions: the flag file (removed by stop_blink), AND the main
  # script still being alive. Inside this background subshell $$ is still the
  # MAIN script's PID (bash keeps $$ across subshells), so if the script dies
  # without running its traps (force-quit, kill -9, closed window), the
  # orphaned blinker notices within one iteration and stops on its own —
  # devices must never keep blinking after the script is gone.
  while [ -f "$flag" ] && kill -0 $$ 2>/dev/null; do
    if [ "$(df "$mp" 2>/dev/null | awk 'NR==2 {print $1}')" = "/dev/${dev}s1" ]; then
      dd if=/dev/zero of="$tmp" bs=64k count=64 2>/dev/null   # ~4 MB, small block avoids a no-op on a nearly-full volume
      sync
      rm -f "$tmp" 2>/dev/null
    else
      break                            # device was pulled — stop; never touch the boot disk
    fi
    sleep 0.3
  done
  rm -f "$tmp" 2>/dev/null
}
stop_blink() {  # signal loops to stop, then make sure their dd children die
  [ -n "$BLINK_FLAG" ] && rm -f "$BLINK_FLAG" 2>/dev/null
  local p
  # ${arr[@]+"${arr[@]}"} expands the array safely even when it is empty (no
  # "unbound variable", no stray empty argument). pkill -P kills the blink
  # subshell's dd child; kill then stops the subshell itself.
  for p in ${BLINK_PIDS[@]+"${BLINK_PIDS[@]}"}; do
    pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
  done
  BLINK_PIDS=()
}
# End-of-run dialog. Blinks the REDO devices this run created (if any) and asks
# whether to run again (for the next batch, or to redo failures). Returns 0 to
# run again, 1 to finish. Works on GUI (dialog) and SSH (terminal y/N).
run_again_prompt() {
  local d mp vn any=0 again=1 ans m
  if [ "$n_redo" -gt 0 ]; then
    BLINK_FLAG="$STATUS_DIR/.blink"; : > "$BLINK_FLAG"; BLINK_PIDS=()
    for d in $redo_devs; do
      # Only blink a volume WE created this run (our $LABEL, or $REDO_LABEL after
      # the rename) and still external — never a foreign volume that survived an
      # erase failure. (Same ownership guard as the rename step.)
      vn=$(diskutil info "${d}s1" 2>/dev/null | sed -n 's/.*Volume Name: *//p')
      case "$vn" in "$LABEL" | "$REDO_LABEL") ;; *) continue ;; esac
      external_physical | grep -qx "$d" || continue
      mp=$(diskutil info "${d}s1" 2>/dev/null | sed -n 's/.*Mount Point: *//p')
      [ -n "$mp" ] && [ -d "$mp" ] || continue
      blink_one "$d" "$mp" "$BLINK_FLAG" &
      BLINK_PIDS+=($!); any=1
    done
    if [ "$any" -eq 1 ]; then
      m="$n_good device(s) loaded; $n_redo did NOT and need redoing."$'\n\n'"All devices blink WHILE loading, so look at them now the run is done and sort by light:"$'\n'"•  STILL BLINKING = failed — LEAVE these connected."$'\n'"•  Solid light = loaded OK — unplug and set aside (still test later)."$'\n'"•  Dark / no light = dead battery, also failed — unplug and set aside to charge fully before retrying."$'\n\n'"Add any more devices you want to load, then click \"Run again\" to redo the still-blinking ones — or \"Done\"."
    else
      m="$n_good device(s) loaded; $n_redo did NOT and need redoing — but none of them shows a blinkable volume right now (unplugged already? battery dead? failed before renaming?)."$'\n\n'"Check Finder for \"$REDO_LABEL\" volumes to find any still connected. Sort the rest by light: solid = loaded (set aside, test later); dark = dead battery (charge fully before retrying)."$'\n\n'"Add any more devices you want to load, then click \"Run again\" — or \"Done\"."
    fi
  elif [ "$n_check" -gt 0 ]; then
    # Content copied, but CHECK devices need a human look (e.g. could-not-eject
    # leaves a device still MOUNTED) — do NOT tell the operator "unplug them all".
    m="$n_good device(s) loaded; $n_check need a look BEFORE unplugging (see the Terminal — e.g. one could not eject and is still mounted)."$'\n\n'"When you've sorted those, connect the next batch if you like, then click \"Run again\" — or \"Done\"."
  else
    m="All $n_good device(s) loaded successfully."$'\n\n'"You may unplug them now (test them for correct content later). Connect the next batch of new devices, then click \"Run again\" — or \"Done\"."
  fi
  if [ "$use_gui" -eq 1 ]; then
    if osascript -e 'on run {t, m}' \
         -e 'button returned of (display dialog m buttons {"Done", "Run again"} default button "Run again" with title t with icon note)' \
         -e 'end run' "$APP_TITLE" "$m" 2>/dev/null | grep -q "Run again"; then
      again=0
    fi
  elif [ -t 0 ]; then
    # Terminal fallback — only when stdin is an interactive TTY. On piped /
    # non-interactive stdin, re-exec would hit EOF and self-cancel, so skip.
    printf '\n%s\n\nRun again? (y/N): ' "$m"
    read -r ans
    [[ $ans =~ ^[Yy]$ ]] && again=0
  fi
  stop_blink
  return $again
}

# ======================== MAIN FLOW STARTS HERE ===========================

# Install the exit cleanup now — before any prompt — so the DSDontWriteUSBStores
# setting is restored no matter how a batch ends (including an early cancel in a
# batch we were re-exec'd into). Both actions inside cleanup() are guarded, so
# running it before STATUS_DIR exists or before we change the setting is a no-op.
trap cleanup EXIT

# --- Ask for the volume label (osascript dialog, CLI fallback) ---------
# The label is the FAT volume name written to every device. Prompting each run
# lets the operator use a NEW label per batch, which is what makes the
# after-the-run "re-plug and check the label" verification meaningful.
if [ "$use_gui" -eq 1 ]; then
  raw=$(osascript -e 'text returned of (display dialog "Volume label for the USB devices." & return & "Letters and numbers, up to 11 - saved as UPPERCASE. Leave as-is for the default." default answer "'"$DEFAULT_LABEL"'" with title "'"$APP_TITLE"'" buttons {"Cancel", "OK"} default button "OK")' 2>/dev/null) || { echo "Cancelled."; exit 0; }
else
  printf 'Volume label for devices [%s]: ' "$DEFAULT_LABEL"
  read -r raw
fi
# FAT32 labels are stored UPPERCASE by the filesystem, so we uppercase here —
# otherwise the post-erase name check further down would reject every device.
# Letters/digits only (punctuation can be silently transformed by diskutil,
# which would also break that check); max 11 chars; blank -> default.
LABEL=$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9' | tr 'a-z' 'A-Z' | cut -c1-11)
[ -z "$LABEL" ] && LABEL="$DEFAULT_LABEL"
if [ "$LABEL" = "$REDO_LABEL" ]; then
  echo "Label '$REDO_LABEL' is reserved for failed devices — please choose another." >&2
  exit 1
fi

# --- Resolve our own real path (so a symlink to the script can't make ---
# --- SRC point at the wrong folder) ----------------------------------
SELF_PATH=$0
while [ -L "$SELF_PATH" ]; do
  link=$(readlink "$SELF_PATH") || break
  case "$link" in
    /*) SELF_PATH=$link ;;
    *)  SELF_PATH="$(dirname "$SELF_PATH")/$link" ;;
  esac
done
SRC="$(cd "$(dirname "$SELF_PATH")" && pwd)"
SELF="$(basename "$SELF_PATH")"

RSYNC_EXCLUDES=(
  --exclude "/$SELF"
  --exclude '*.app' --exclude '*.zip'
  --exclude '*.cmd' --exclude '*.CMD'
  --exclude '*.txt' --exclude '*.TXT'
  --exclude '*.md' --exclude '*.html' --exclude '/images'
  --exclude '._*' --exclude '.DS_Store' --exclude '.Spotlight-V100'
  --exclude '.fseventsd' --exclude '.Trashes' --exclude '.TemporaryItems'
)

# --- Which PHYSICAL disks hold the source? Never erase those. ---------
# df reports the mounted (possibly APFS-synthesized) device; walk it back
# to the physical disk(s): Part of Whole -> APFS Physical Store(s).
src_node=$(df "$SRC" | awk 'NR==2 {print $1}')
src_node=${src_node#/dev/}
src_whole=$(diskutil info "$src_node" 2>/dev/null | sed -n 's/.*Part of Whole: *//p')
src_disks="${src_whole:-$src_node}"
for store in $(diskutil info "$src_whole" 2>/dev/null | sed -n 's/.*APFS Physical Store: *//p'); do
  w=$(diskutil info "$store" 2>/dev/null | sed -n 's/.*Part of Whole: *//p')
  src_disks="$src_disks ${w:-$store}"
done
is_src_disk() { case " $src_disks " in *" $1 "*) return 0 ;; esac; return 1; }

external_physical() {
  diskutil list external physical | sed -n 's|^/dev/\([a-z0-9]*\).*|\1|p'
}
disk_bytes() {
  diskutil info "$1" 2>/dev/null | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes.*/\1/p'
}

# --- Enumerate candidate disks, capturing identity for later re-checks ---
devices=()   # diskN identifiers
dev_bytes=() # exact size in bytes, to detect device renumbering later
labels=()    # human lines for the picker
# Fed by  < <(external_physical)  at the matching `done` below — a PROCESS
# SUBSTITUTION, not a pipe, so this loop runs in the CURRENT shell and the three
# arrays it fills survive. (A pipe would run the loop body in a subshell and the
# arrays would come back empty — a classic bash gotcha.)
while IFS= read -r dev; do
  if is_src_disk "$dev"; then
    echo "Skipping $dev — it holds the source content"
    continue
  fi
  # Cards hard-locked via their CSD write-protect bit (MegaVoice-style)
  # enumerate as read-only media — detect and skip, don't fail confusingly
  # Field label changed across macOS versions: 10.15+ prints "Media Read-Only",
  # earlier releases printed "Read-Only Media" — match both or the guard is
  # silently inert on the older systems we claim to support.
  if diskutil info "$dev" | grep -qE '(Media Read-Only|Read-Only Media): *Yes'; then
    echo "Skipping $dev — WRITE-PROTECTED (unlock it first, e.g. green button on the card locker)"
    continue
  fi
  bytes=$(disk_bytes "$dev")
  size_h=$(diskutil info "$dev" | sed -n 's/.*Disk Size: *\([^(]*\)(.*/\1/p' | sed 's/ *$//')
  media=$(diskutil info "$dev" | sed -n 's|.*Device / Media Name: *||p')
  # Volume names across ALL partitions of this disk, so a multi-partition
  # drive is obviously one disk (one row) with several volumes on it.
  # APFS partitions keep their volumes on a synthesized container disk —
  # follow the "Container diskN" reference so those names show up too.
  vols=""; nvol=0
  for lst in "$dev" $(diskutil list "$dev" | awk '{for (i = 1; i < NF; i++) if ($i == "Container") print $(i + 1)}'); do
    for id in $(diskutil list "$lst" 2>/dev/null | awk '/^ *[0-9]+:/ {print $NF}'); do
      nm=$(diskutil info "$id" 2>/dev/null | sed -n 's/.*Volume Name: *//p')
      case "$nm" in "" | "Not applicable"*) continue ;; esac
      vols="$vols, $nm"; nvol=$((nvol + 1))
    done
  done
  vols=${vols#, }
  case $nvol in
    0) voltxt="no named volumes" ;;
    1) voltxt="volume: $vols" ;;
    *) voltxt="$nvol volumes: $vols" ;;
  esac
  devices+=("$dev")
  dev_bytes+=("${bytes:-0}")
  labels+=("$dev — ${size_h:-?} — $voltxt — ${media:-unknown device}")
done < <(external_physical)

[ ${#devices[@]} -gt 0 ] || {
  echo "No usable external disks found."
  gui_alert "$APP_TITLE" "No external USB devices were found. Check that the hub is connected and powered and the devices are inserted, then run again."
  exit 1
}

echo "Source: $SRC ($(du -sh "$SRC" 2>/dev/null | awk '{print $1}'))"

# --- Native GUI picker via osascript (present on every Mac). -----------
# Rows are whole physical DISKS (all volumes on a disk are erased
# together). All rows preselected; Cmd-click deselects a disk to KEEP.
# A second dialog confirms exactly what will be erased vs kept, which
# also defuses the plain-click-replaces-selection trap.
gui_pick() {
  osascript - "$APP_TITLE" "$@" <<'APPLESCRIPT'
on run argv
	set appTitle to item 1 of argv
	set devs to rest of argv
	try
		set n to (count of devs) as text
		repeat
			set btn to button returned of (display dialog n & " external disks detected." & linefeed & linefeed & "Selected disks will be COMPLETELY ERASED — every partition and volume on each selected disk is wiped — and then loaded with your audio content." buttons {"Cancel", "Show in Finder", "Choose disks…"} default button "Choose disks…" with icon caution with title appTitle)
			if btn is "Choose disks…" then exit repeat
			if btn is "Show in Finder" then do shell script "open /Volumes"
		end repeat
		set text item delimiters to linefeed
		repeat
			set sel to choose from list devs with title appTitle with prompt "Each row is ONE PHYSICAL DISK (a disk may hold several volumes — they are erased together). All disks are selected. Cmd-click any disk you want to KEEP, to deselect it." default items devs OK button name "Continue…" with multiple selections allowed
			if sel is false then return "CANCELLED"
			set keepList to {}
			repeat with d in devs
				set dt to d as text
				if sel does not contain dt then set end of keepList to dt
			end repeat
			set msg to "ERASE these " & ((count of sel) as text) & " disk(s) — ALL volumes on them will be wiped:" & linefeed & (sel as text)
			if (count of keepList) > 0 then set msg to msg & linefeed & linefeed & "KEEP these (not touched):" & linefeed & (keepList as text)
			set btn2 to button returned of (display dialog msg buttons {"Back", "Cancel", "Erase & Load"} default button "Back" with icon caution with title appTitle)
			if btn2 is "Erase & Load" then return sel as text
			-- "Back" -> show the list again
		end repeat
	on error number -128
		return "CANCELLED"
	end try
end run
APPLESCRIPT
}

if [ "$use_gui" -eq 1 ] && picked=$(gui_pick "${labels[@]}" 2>/dev/null); then
  case "$picked" in
    "" | CANCELLED) echo "Cancelled."; exit 0 ;;
  esac
  # Turn the picker's returned lines ("diskN — 7.8 GB — volume: … — …") back
  # into bare diskN identifiers: ${line%% *} strips from the first space on;
  # <<< feeds the multi-line string in as stdin (a here-string).
  sel_devs=()
  while IFS= read -r line; do
    sel_devs+=("${line%% *}")
  done <<< "$picked"
  # Keep devices/dev_bytes index-aligned by filtering the originals
  new_devices=(); new_bytes=()
  for idx in "${!devices[@]}"; do
    for sd in "${sel_devs[@]}"; do
      if [ "${devices[idx]}" = "$sd" ]; then
        new_devices+=("${devices[idx]}"); new_bytes+=("${dev_bytes[idx]}")
        break
      fi
    done
  done
  devices=("${new_devices[@]}"); dev_bytes=("${new_bytes[@]}")
  [ ${#devices[@]} -gt 0 ] || { echo "Nothing selected."; exit 0; }
  echo "Will erase and load ${#devices[@]} disk(s):"
  echo "$picked" | sed 's/^/    /'
else
  # No GUI available (e.g. SSH session) — text confirmation, all-or-nothing
  echo "(GUI selection unavailable — using text mode.)"
  i=1
  for l in "${labels[@]}"; do printf '%3d) %s\n' "$i" "$l"; i=$((i + 1)); done
  echo "NOTE: these are whole DISKS — every volume on each disk is erased."
  read -p "Erase ALL ${#devices[@]} disks and copy the content onto each? (y/N): " confirm
  [[ $confirm =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# --- Consent given -----------------------------------------------------
# Suppress Finder's .DS_Store-on-USB behaviour for the duration of the run so a
# .DS_Store never lands on a device ahead of the content. cleanup() restores the
# Mac's original value when the whole session ends. Skip the read on a re-exec —
# $DSUSB_ORIG already holds the TRUE original (exported across exec); reading now
# would just re-capture the value we ourselves set on run 1.
if [ -z "${DSUSB_ORIG+x}" ]; then
  DSUSB_ORIG=$(defaults read com.apple.desktopservices DSDontWriteUSBStores 2>/dev/null)
  # `defaults read` can return 1/0 OR true/false/YES/NO depending on how the
  # key was written — normalize so restore_dsusb restores rather than deletes
  # a value someone had set by hand.
  case "$DSUSB_ORIG" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) DSUSB_ORIG=1 ;;
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) DSUSB_ORIG=0 ;;
    *) DSUSB_ORIG="" ;;   # key absent (or unrecognized) -> delete on restore
  esac
  export DSUSB_ORIG
fi
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
# NOTE: the SOURCE folder is deliberately left untouched — rsync's --exclude list
# already keeps .DS_Store/._* from being copied, so there's no need to strip the
# source's own xattrs or delete files from it. The only per-device junk (._*
# AppleDouble sidecars, synthesized on FAT) is scrubbed off each device, not here.

# --- Payload size, measured the way rsync will actually copy it --------
payload_b=$(cd "$SRC" && find . \( -name '*.app' -o -name '.fseventsd' -o -name '.Spotlight-V100' \
    -o -name '.Trashes' -o -name '.TemporaryItems' -o -path './images' \) -prune -o \
  -type f ! -name "$SELF" ! -name '*.zip' \
  ! -name '*.cmd' ! -name '*.CMD' ! -name '*.txt' ! -name '*.TXT' \
  ! -name '*.md' ! -name '*.html' \
  ! -name '._*' ! -name '.DS_Store' -print0 |
  xargs -0 stat -f %z 2>/dev/null | awk '{s += $1} END {printf "%d", s}')
total_k=$(((payload_b + 1023) / 1024))
[ "$total_k" -gt 0 ] || total_k=1

# Private scratch dir for the per-device status files (see the header block).
# cleanup() (the EXIT trap installed at the top of MAIN FLOW) removes it however
# the script ends — except across `exec` (the run-again path removes it by hand
# first, since exec does not fire EXIT traps).
STATUS_DIR=$(mktemp -d)

on_interrupt() {
  trap '' INT TERM HUP                         # disarm so a second signal can't re-enter this
  printf '\n\nInterrupted!\n'
  stop_blink                                   # stop blink loops + their dd children first
  jobs -p 2>/dev/null | xargs kill 2>/dev/null
  wait 2>/dev/null
  incomplete=""
  for dev in ${copy_devs[@]+"${copy_devs[@]}"}; do
    [ -f "$STATUS_DIR/$dev" ] || incomplete="$incomplete $dev"
  done
  if [ -n "$incomplete" ]; then
    echo "These devices are INCOMPLETE — do NOT hand them out; re-run the script."
    echo "(They may still carry the \"${LABEL:-batch}\" name and look loaded in Finder"
    echo "— do not trust the label; only a completed run counts.)"
    for d in $incomplete; do echo "  $d"; done
  fi
  exit 130
}
# HUP included: closing the Terminal window mid-run (or mid-dialog) must run
# the same teardown — without it, bash dies without firing the EXIT trap and
# the blink loops would be orphaned, still writing to devices.
trap on_interrupt INT TERM HUP

SECONDS=0   # bash builtin: seconds since this assignment — drives ETA, stall detection, total

# --- Erase phase (parallel, verified, one retry, results recorded) -----
# One background subshell per disk (the `( … ) &` below). Each re-verifies the
# disk's identity, runs eraseDisk (one retry), and records its outcome as a
# marker file in $STATUS_DIR. `wait` blocks until all have finished.
echo "Erasing ${#devices[@]} disk(s) (parallel)..."
for idx in "${!devices[@]}"; do
  dev=${devices[idx]}
  want=${dev_bytes[idx]}
  (
    # Re-verify identity RIGHT BEFORE erasing: same size, still listed as
    # external+physical. Disk numbers get reused when devices are
    # unplugged/replugged, and the picker may have been open a while.
    if [ "$(disk_bytes "$dev")" != "$want" ] || ! external_physical | grep -qx "$dev"; then
      echo "device changed since the list was shown — skipped for safety" > "$STATUS_DIR/$dev.notloaded"
      echo "  SKIPPED $dev — device changed since the list was shown" >&2
      exit 0
    fi
    if diskutil eraseDisk FAT32 "$LABEL" MBRFormat "/dev/$dev" >/dev/null 2>&1 ||
       { sleep 2; diskutil eraseDisk FAT32 "$LABEL" MBRFormat "/dev/$dev" >/dev/null 2>&1; }; then
      : > "$STATUS_DIR/$dev.erased"
      echo "  erased  $dev"
    else
      echo "erase failed (tried twice)" > "$STATUS_DIR/$dev.notloaded"
      echo "  ERASE FAILED: $dev" >&2
    fi
  ) &
done
wait

# --- Prepare phase: mount and verify each freshly erased volume --------
echo "Preparing volumes..."
copy_devs=()   # disks that erased, mounted, AND verified as ours -> get copied to
mps=()         # their mount points, e.g. /Volumes/PLAYER (index-aligned with copy_devs[])
for dev in "${devices[@]}"; do
  [ -f "$STATUS_DIR/$dev.erased" ] || continue   # skip disks the erase phase didn't mark good
  mp=$(diskutil info "${dev}s1" | sed -n 's/.*Mount Point: *//p')
  if [ -z "$mp" ]; then
    diskutil mount "${dev}s1" >/dev/null 2>&1
    mp=$(diskutil info "${dev}s1" | sed -n 's/.*Mount Point: *//p')
  fi
  if [ -z "$mp" ]; then
    echo "erased, but volume would not mount" > "$STATUS_DIR/$dev.notloaded"
    echo "  SKIPPING $dev — no mount point" >&2
    continue
  fi
  # The mounted volume must be OUR fresh one: right label, right device
  volname=$(diskutil info "${dev}s1" | sed -n 's/.*Volume Name: *//p')
  df_dev=$(df "$mp" 2>/dev/null | awk 'NR==2 {print $1}')
  if [ "$volname" != "$LABEL" ] || [ "$df_dev" != "/dev/${dev}s1" ]; then
    echo "post-erase volume looks wrong (name '$volname') — skipped" > "$STATUS_DIR/$dev.notloaded"
    echo "  SKIPPING $dev — unexpected volume after erase" >&2
    continue
  fi
  # Prevention, before anything else touches the fresh volume
  mdutil -i off "$mp" >/dev/null 2>&1
  mkdir "$mp/.fseventsd" 2>/dev/null; touch "$mp/.fseventsd/no_log"
  copy_devs+=("$dev")
  mps+=("$mp")
done

[ ${#copy_devs[@]} -gt 0 ] || {
  echo "Nothing to copy to."
  gui_alert "$APP_TITLE" "None of the selected devices could be prepared (erase or mount failed). Nothing was loaded. Re-seat them and run again."
  exit 1
}
grand_k=$((total_k * ${#copy_devs[@]}))
[ "$grand_k" -gt 0 ] || grand_k=1

# --- Copy phase (parallel) ---------------------------------------------
# One background subshell per device: rsync the content, scrub macOS junk,
# eject, and write a single OK/CHECK/REDO status file. The main PROGRESS loop
# (further down) watches those files rather than waiting here, so it can draw a
# live bar and detect stalls while the copies run.
echo "Copying to ${#copy_devs[@]} device(s) (parallel)..."
pids=()   # PID of each copy subshell (index-aligned with copy_devs[]/mps[])
for idx in "${!copy_devs[@]}"; do
  dev=${copy_devs[idx]}
  mp=${mps[idx]}
  (
    # The mount point must still be THIS device — if the device dropped
    # off, /Volumes/<name> may be gone (or belong to something else),
    # and writing there would land on the internal disk.
    ok_mount() { [ "$(df "$mp" 2>/dev/null | awk 'NR==2 {print $1}')" = "/dev/${dev}s1" ]; }
    # Status files start with a one-word CODE the summary groups on:
    #   OK    = loaded and ejected (detached; safe to pull)
    #   CHECK = content copied but something needs a human look
    #   REDO  = not loaded; retry this device
    ok_mount || { echo "REDO volume disappeared before copy" > "$STATUS_DIR/$dev"; exit 1; }
    # rsync transfers its file list in sorted path order, so files land
    # on the FAT in name order — same effect as a find|sort pipe
    if rsync -rt "${RSYNC_EXCLUDES[@]}" "$SRC/" "$mp/" \
         >/dev/null 2>"$STATUS_DIR/$dev.err" && ok_mount; then
      # Scrub the junk macOS forces onto FAT. On modern macOS ._* sidecars
      # are synthesized for any file carrying com.apple.provenance (which
      # xattr -cr can't strip), so they CANNOT be prevented — only removed.
      # ._* and .DS_Store are ordinary files and delete cleanly.
      # NOTE: we intentionally do NOT chflags uchg / write-protect the files.
      # That would re-create ._* sidecars that can't be reliably removed on a
      # multi-file volume, and a CLEAN device matters more (Android ignores
      # the read-only flag anyway). See the project notes if this is revisited.
      dot_clean -m "$mp" 2>/dev/null
      find "$mp" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null
      # .Spotlight-V100 (created by mdutil) and .fseventsd are SIP-protected /
      # unavoidable and harmless on the players — left as-is, NOT counted as
      # junk. Anything below survived the scrub, so it is genuinely unexpected.
      junk=$(find "$mp" -mindepth 1 \
               \( -name '._*' -o -name '.DS_Store' \
                  -o -name '.Trashes' -o -name '.TemporaryItems' \) 2>/dev/null)
      # Eject with a couple of retries — a lingering indexer/Finder handle
      # usually clears within a second or two, avoiding a false "could not
      # eject" that would otherwise leave a good device to be redone.
      try_eject() {
        diskutil eject "/dev/$dev" >/dev/null 2>&1 && return 0
        sleep 2; diskutil eject "/dev/$dev" >/dev/null 2>&1 && return 0
        sleep 2; diskutil eject "/dev/$dev" >/dev/null 2>&1
      }
      if [ -n "$junk" ]; then
        try_eject
        echo "CHECK content OK but junk appeared: $(echo "$junk" | tr '\n' ' ')" > "$STATUS_DIR/$dev"
      elif try_eject; then
        echo "OK loaded and ejected" > "$STATUS_DIR/$dev"
      else
        echo "CHECK content OK but could not eject — eject it in Finder, then unplug" > "$STATUS_DIR/$dev"
      fi
    else
      echo "REDO copy failed: $(tail -1 "$STATUS_DIR/$dev.err" 2>/dev/null)" > "$STATUS_DIR/$dev"
    fi
  ) &
  pids+=($!)
done

# --- PROGRESS: poll status files + df; draw bar; detect stalls ---------
# The parent loops here while the copy subshells run. Progress is ESTIMATED
# from each volume's `df` used-kB (rsync gives no per-device progress when run
# in parallel), summed across devices and divided by the expected grand total.
# A device is "done" the instant its status file appears; its OK/CHECK/REDO
# outcome is printed once, in colour. A device whose used-kB has not grown for
# STALL_LIMIT seconds is killed and marked REDO. Loop exits when all are done.
start=$SECONDS
announced=" "                  # space-delimited set of devices already announced (printed once)
# Per-device progress trackers: last_used[] = highest used-kB seen on the volume
# so far; last_move[] = the SECONDS value when it last increased. A device whose
# used-kB hasn't grown for STALL_LIMIT seconds is declared stalled and killed.
for idx in "${!copy_devs[@]}"; do
  last_used[idx]=0
  last_move[idx]=$SECONDS
  gone_polls[idx]=0   # consecutive polls where df no longer showed OUR device
done

while :; do
  done_k=0
  finished=0
  for idx in "${!copy_devs[@]}"; do
    dev=${copy_devs[idx]}
    mp=${mps[idx]}
    if [ -f "$STATUS_DIR/$dev" ]; then
      finished=$((finished + 1))
      done_k=$((done_k + total_k))
      case "$announced" in *" $dev "*) ;; *)
        # A status file can exist for a sub-millisecond instant while the
        # subshell has truncated it but not yet written — read empty then,
        # so defer announcing until it has settled (next poll).
        st=$(head -1 "$STATUS_DIR/$dev")
        if [ -n "$st" ]; then
          announced="$announced$dev "
          printf '\r%-78s\r' ' '
          case "$st" in
            OK*)    echo "  ${cGRN}OK    $dev loaded and ejected — safe to unplug${cR}" ;;
            CHECK*) echo "  ${cYEL}${cB}CHECK${cR} $dev: ${st#CHECK }" ;;
            *)      echo "  ${cRED}${cB}REDO${cR}  $dev: ${st#REDO }" ;;
          esac
        fi ;;
      esac
      continue
    fi
    used=$(df -k "$mp" 2>/dev/null | awk -v d="/dev/${dev}s1" '$1 == d {print $3}')
    if [ -n "$used" ]; then
      gone_polls[idx]=0
      [ "$used" -gt "$total_k" ] && used=$total_k
      if [ "$used" -gt "${last_used[idx]}" ]; then
        last_used[idx]=$used
        last_move[idx]=$SECONDS
      elif [ $((SECONDS - last_move[idx])) -ge "$STALL_LIMIT" ]; then
        pkill -P "${pids[idx]}" 2>/dev/null
        kill "${pids[idx]}" 2>/dev/null
        echo "REDO stalled — no write progress for ${STALL_LIMIT}s; device may be bad" > "$STATUS_DIR/$dev"
      fi
      done_k=$((done_k + used))
    else
      # df no longer resolves this mount point to OUR device — the device was
      # yanked or its volume vanished. rsync does NOT stop on its own: it keeps
      # creating the remaining files by path, and if macOS left /Volumes/<label>
      # behind as a plain folder, those writes land on the BOOT DISK. ok_mount
      # only guards before/after rsync; this is the DURING guard. Two misses in
      # a row (~4 s) before acting, so one transient df hiccup can't kill a
      # healthy copy — safety still beats completion.
      gone_polls[idx]=$((gone_polls[idx] + 1))
      if [ "${gone_polls[idx]}" -ge 2 ] && kill -0 "${pids[idx]}" 2>/dev/null; then
        pkill -P "${pids[idx]}" 2>/dev/null
        kill "${pids[idx]}" 2>/dev/null
        st_msg="REDO volume disappeared during copy (device unplugged or died?)"
        # If a ghost /Volumes/<label> folder remains ON THE BOOT DISK, remove
        # the spilled files. Triple-guarded: path is under /Volumes/, it is a
        # real directory, and df resolves it to the SAME device node as the
        # /Volumes parent directory — true only for a plain folder (which lives
        # on its parent's filesystem), never for a mounted volume (which shows
        # its own device). NB: compare to /Volumes, NOT / — on modern macOS the
        # root is a sealed snapshot on a different device node than the Data
        # volume that actually hosts /Volumes.
        case "$mp" in /Volumes/?*)
          if [ -d "$mp" ] &&
             [ "$(df "$mp" 2>/dev/null | awk 'NR==2 {print $1}')" = "$(df /Volumes 2>/dev/null | awk 'NR==2 {print $1}')" ]; then
            rm -rf "$mp" 2>/dev/null
            st_msg="$st_msg — stray boot-disk folder cleaned up"
          fi ;;
        esac
        echo "$st_msg" > "$STATUS_DIR/$dev"
      fi
      done_k=$((done_k + last_used[idx]))
    fi
  done

  elapsed=$((SECONDS - start)); [ "$elapsed" -lt 1 ] && elapsed=1
  rate_k=$((done_k / elapsed))
  pct=$((done_k * 100 / grand_k)); [ "$pct" -gt 100 ] && pct=100
  if [ "$rate_k" -gt 0 ]; then
    eta=$(((grand_k - done_k) / rate_k))
    eta_str=$(printf '%d:%02d' $((eta / 60)) $((eta % 60)))
  else
    eta_str="--:--"
  fi
  bars=$((pct * 30 / 100))
  # Pre-pad the bar to 30 chars, THEN wrap in color, so the color escapes
  # don't throw off printf's field width.
  bar=$(printf '%-30s' "$(printf '%*s' "$bars" '' | tr ' ' '#')")
  # Show progress in the Terminal tab/title too, so it's visible even when
  # the window is in the background or the Dock.
  set_title "$APP_TITLE — $pct% ($finished/${#copy_devs[@]} done, ETA $eta_str)"
  printf '\r[%s%s%s] %s%3d%%%s  %2d.%d MB/s  ETA %6s  %d/%d devices done ' \
    "$cCYN" "$bar" "$cR" "$cB" "$pct" "$cR" \
    $((rate_k / 1024)) $(((rate_k % 1024) * 10 / 1024)) \
    "$eta_str" "$finished" "${#copy_devs[@]}"

  [ "$finished" -ge ${#copy_devs[@]} ] && break

  # Backstop: if every copy job is gone but statuses are missing, record it
  alive=0
  for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)); done
  if [ "$alive" -eq 0 ]; then
    sleep 1
    for idx in "${!copy_devs[@]}"; do
      [ -f "$STATUS_DIR/${copy_devs[idx]}" ] ||
        echo "REDO copy process ended without reporting (unplugged?)" > "$STATUS_DIR/${copy_devs[idx]}"
    done
  fi
  sleep 2
done
wait 2>/dev/null
printf '\n'

# --- Results -------------------------------------------------------------
# Bucket every device by the one-word code at the front of its status.
good_list=""; check_list=""; redo_list=""; redo_devs=""
for idx in "${!copy_devs[@]}"; do
  dev=${copy_devs[idx]}
  st=$(head -1 "$STATUS_DIR/$dev" 2>/dev/null || echo "REDO no status (unknown)")
  case "$st" in
    OK*)    good_list="$good_list  $dev — loaded and ejected"$'\n' ;;
    CHECK*) check_list="$check_list  $dev — ${st#CHECK }"$'\n' ;;
    *)      redo_list="$redo_list  $dev — ${st#REDO }"$'\n'; redo_devs="$redo_devs $dev" ;;
  esac
done
# Devices that never reached the copy phase (erase/mount problems) also REDO
for f in "$STATUS_DIR"/*.notloaded; do
  [ -e "$f" ] || continue
  d=$(basename "$f" .notloaded)
  redo_list="$redo_list  $d — $(head -1 "$f")"$'\n'; redo_devs="$redo_devs $d"
done

# Make the failures self-labeling: rename their volume to REDO so they are
# obvious on the desktop and in the next run's picker (best-effort — a truly
# dead device can't be renamed, and that's fine). GUARD: only relabel a
# volume we actually created this run (still external, still carrying our
# $LABEL) — never a disk whose number was reused by an unrelated drive.
for d in $redo_devs; do
  vn=$(diskutil info "${d}s1" 2>/dev/null | sed -n 's/.*Volume Name: *//p')
  if [ "$vn" = "$LABEL" ] && external_physical | grep -qx "$d"; then
    diskutil rename "/dev/${d}s1" "$REDO_LABEL" >/dev/null 2>&1
  fi
done

echo
echo "${cDIM}================ RESULTS ================${cR}"
n_good=$(printf '%s' "$good_list" | grep -c .)
n_check=$(printf '%s' "$check_list" | grep -c .)
n_redo=$(printf '%s' "$redo_list" | grep -c .)
if [ "$n_good" -gt 0 ]; then
  echo "${cGRN}${cB}GOOD${cR} — loaded, ejected, safe to pull ($n_good):"
  printf '%s' "$good_list"
fi
if [ "$n_check" -gt 0 ]; then
  echo "${cYEL}${cB}CHECK${cR} — content copied, but look at these ($n_check):"
  printf '%s' "$check_list"
fi
if [ "$n_redo" -gt 0 ]; then
  echo "${cRED}${cB}REDO${cR} — NOT loaded, retry these ($n_redo):"
  printf '%s' "$redo_list"
  echo
  echo "${cB}WHAT TO DO NOW${cR}"
  echo "--------------"
  echo "$n_good device(s) loaded fine and were EJECTED — they have dropped"
  echo "off the Mac and will NOT be touched if you run again."
  echo
  echo "$n_redo device(s) failed; those still connected have been renamed \"$REDO_LABEL\"."
  echo "All devices blink WHILE loading; the ones STILL blinking now are the failures."
  echo "LEAVE those connected. Unplug the rest and sort them: solid light = finished"
  echo "(set aside, test later); no light = dead battery (set aside to charge fully)."
  echo "Then add any fresh devices and click \"Run again\" to redo the still-blinking ones."
  echo "Re-seat a failing device's cable; try a different cable and port too."
  echo "Contact cleaner on the connector, or a full charge, can fix stubborn ones."
  echo "In Finder under \"$COMPUTER_NAME\", the failed devices show as \"$REDO_LABEL\""
  echo "volumes (your source drive, if it is USB, and any CHECK device that could"
  echo "not eject also remain). They are still MOUNTED, so accidentally pulling one"
  echo "gives an \"unsafe removal\" warning — a sign you grabbed a failed device"
  echo "instead of a finished (ejected) one. Unplug one at a time and watch for a"
  echo "\"$REDO_LABEL\" to vanish from Finder to identify it."
  echo
  echo "${cYEL}Also watch for DARK devices:${cR} a device whose battery died or that"
  echo "switched off mid-copy shows NO light at all (not blinking). It failed too"
  echo "and must be redone, even though it isn't blinking. A steady/solid light"
  echo "means it finished — but still check its content before distributing."
  echo "IMPORTANT: the loading cable/hub may NOT charge a dead device — plugging"
  echo "it back in may not wake it. Charge it FULLY first (in the sun, or with a"
  echo "proper charging cable) before reconnecting it to reload."
  echo
  echo "To retry the failures: use the \"Run again\" dialog (or re-run the script)."
  echo "The loaded devices have already ejected, so the next run lists only what is"
  echo "still connected — the $REDO_LABEL failures, plus anything else still plugged"
  echo "in (a CHECK device, another drive): deselect anything you don't want erased."
elif [ "$n_check" -eq 0 ]; then
  echo "${cGRN}All $n_good device(s) loaded successfully and were ejected — safe to"
  echo "unplug them all.${cR}"
fi
echo "${cDIM}=========================================${cR}"

# --- Verify (ALWAYS shown — some failures cannot be auto-detected) ------
echo
echo "${cB}IMPORTANT — check your devices before handing them out${cR}"
echo "This tool cannot catch every failure. A device that fully disconnected"
echo "or lost power partway through can still be reported as loaded, and blank"
echo "or half-written devices are not always obvious."
echo "To be sure, TEST them:"
vstep=1
if [ "$n_redo" -gt 0 ]; then
  echo "  $vstep. Pull the failed (${REDO_LABEL}) devices first (identified above)."; vstep=$((vstep + 1))
fi
echo "  $vstep. Unplug and re-plug the rest — or re-plug the whole hub — and confirm"
echo "     each one comes back mounted with the label \"${LABEL}\"."; vstep=$((vstep + 1))
echo "  $vstep. Check one device at a time — and spot-play a track in a real player."
echo "  ${cDIM}Tip: use a NEW, unused label for each batch. Then any device that"
echo "  quietly kept its OLD content (never really written) is easy to spot.${cR}"
echo
echo "Finished in $((SECONDS / 60))m $((SECONDS % 60))s."

# --- Attention-grabbers for an operator who walked away ----------------
set_title "$APP_TITLE — finished ($n_good ok, $n_redo redo)"
if [ "$n_redo" -gt 0 ]; then
  notify "$APP_TITLE" "$n_good loaded, $n_redo need redo. See Terminal."
elif [ "$n_check" -gt 0 ]; then
  notify "$APP_TITLE" "$n_good loaded; $n_check need a look. See Terminal."
else
  notify "$APP_TITLE" "All $n_good devices loaded successfully — safe to unplug."
fi

# Offer to run again — for the next batch, or to redo the failures. This blinks
# any failed devices while the dialog is up. On "Run again" we clean up and
# restart fresh (the EXIT trap does NOT fire across exec, so remove STATUS_DIR
# here). stop_blink already ran inside run_again_prompt, so no writer survives.
if run_again_prompt; then
  set_title ""
  rm -rf "$STATUS_DIR"
  echo
  echo "${cB}Starting another run...${cR}"
  echo
  exec bash "$SELF_PATH"
fi

[ "$n_redo" -eq 0 ] || exit 1
