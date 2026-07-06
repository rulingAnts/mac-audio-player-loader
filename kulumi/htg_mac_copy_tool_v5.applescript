-- HTG Mac Copy Tool v5 (fixes the on-device play-order bug in v4)
--
-- WHY: FAT players play files in raw directory-entry order, not name order.
-- v4 built a name-sorted file list but copied it with rsync; Apple's rsync
-- (openrsync) writes each file as a ".name.XXXXXX" temp file and renames it
-- into place, and on FAT every rename re-allocates the directory entry
-- FIRST-FIT into slots freed by earlier temp entries — so the final entry
-- order comes out scrambled (name-length dependent: uniform short names can
-- pass by luck, varied-length names fail). The sorted list was correct; the
-- copying tool betrayed it.
--
-- HOW v5 WORKS:
--   * An ordered writer replaces rsync: every folder and file is created
--     with its FINAL name, in strict LC_ALL=C name-sorted order — no temp
--     files, no renames — so each FAT directory entry is allocated in play
--     order. NEVER swap rsync/ditto/mv back in: any temp-and-rename copier
--     re-scrambles the order.
--   * Folders are enumerated and sorted along with files: a folder's entry
--     in its PARENT directory is allocated at mkdir time, so folders must
--     be created in the same sorted sequence as everything else.
--   * The command runs as a script file via /bin/bash in a Terminal window,
--     instead of being typed into the user's interactive shell: interactive
--     zsh parses typed text differently from a script ("#" is not a comment
--     by default, "!" history expansion is live, and user aliases such as
--     cp='cp -i' apply), so a multi-line program must never be delivered
--     as keystrokes.
--   * Every user-chosen path passes through "quoted form of" — $, backticks
--     and quotes are legal in folder and volume names, and unquoted they
--     are live shell syntax (a target named MUSIC$2 would silently copy to
--     /Volumes/MUSIC/ instead).
--   * The order guarantee needs an EMPTY target: use NUKE + Copy, or a
--     freshly formatted volume. Entries that already exist keep their
--     directory slots, and overwriting a file does not move its entry.
--     (NUKE tolerates the SIP-protected .Spotlight-V100 index, which
--     macOS will not let anyone delete; a fresh format is the cleanest
--     possible baseline.)
property excludeList : {".Spotlight-V100", ".Trashes", "._*", "MAC_Exclude.txt", "*.CMD", "*.sh", "System Volume Information", ".TemporaryItems", "dir_nt"}

on run
	-- Select source
	set srcFolder to choose folder with prompt "Select the SOURCE folder:"
	set srcPath to POSIX path of srcFolder

	-- Select target
	set tgtFolder to choose folder with prompt "Select the TARGET folder:"
	set tgtPath to POSIX path of tgtFolder

	-- Confirm
	set msgText to "SOURCE:
" & srcPath & "

TARGET:
" & tgtPath & "

Proceed?"
	set buttonChoice to button returned of (display dialog msgText buttons {"Cancel", "Copy", "NUKE + Copy"} default button "Copy")
	if buttonChoice = "Cancel" then return

	-- Build exclude args as a find -prune group (v4 chained "-not -name",
	-- which hid an excluded folder's own name but still copied the files
	-- INSIDE it; pruning skips excluded folders with their whole contents)
	set exArgs to ""
	repeat with e in excludeList
		if exArgs is "" then
			set exArgs to "-name \"" & e & "\""
		else
			set exArgs to exArgs & " -o -name \"" & e & "\""
		end if
	end repeat

	-- Nuke mode. Hidden entries are removed too: the sh glob * skips
	-- dot-names, so ._* AppleDouble files (the very junk the exclude list
	-- keeps off the device) and .DS_Store would survive a plain "$TGT"/* —
	-- and leftover entries fragment the FAT directory, so first-fit
	-- allocation into the gaps can reorder the new entries. Emptying the
	-- root as completely as possible is part of the order guarantee.
	-- (.[!.]* and ..?* cover dot-names while never matching "." or "..";
	-- rm -f exits 0 when a glob matches nothing and is passed literally.)
	--
	-- rm errors are tolerated (2>/dev/null): SIP protects Spotlight's
	-- .Spotlight-V100 index on external volumes — it cannot be deleted even
	-- with sudo — and macOS may recreate .fseventsd/.DS_Store between the
	-- rm and the check. Those system entries are invisible to players and
	-- harmless. But anything ELSE surviving means the volume is only
	-- half-erased, so the script stops rather than copy onto it.
	if buttonChoice = "NUKE + Copy" then
		display dialog "NUKING TARGET in 3 seconds..." giving up after 1
		display dialog "2..." giving up after 1
		display dialog "1..." giving up after 1
		set leftover to do shell script ("rm -rf " & quoted form of tgtPath & "/* " & quoted form of tgtPath & "/.[!.]* " & quoted form of tgtPath & "/..?* 2>/dev/null
ls -A " & quoted form of tgtPath & " | grep -vxE '[.](Spotlight-V100|fseventsd|Trashes|TemporaryItems|DS_Store)' || true")
		if leftover is not "" then
			display dialog "NUKE could not remove:

" & leftover & "

Stopping — play order cannot be guaranteed on a half-erased volume. Eject and re-plug the drive and try again, or reformat it (Disk Utility, MS-DOS/FAT32), then run this tool again." buttons {"OK"} default button "OK" with icon stop
			return
		end if
	end if

	-- Private work directory for the script + file list (fixed names in
	-- world-writable /tmp can collide across users or be pre-created by
	-- another local account; mktemp -d gives this run its own 0700 dir)
	set workDir to do shell script "/usr/bin/mktemp -d /tmp/htg_copy.XXXXXX"
	set fileList to workDir & "/htg_filelist.txt"
	set scriptFile to workDir & "/htg_copy.sh"

	-- ORDERED WRITER. The find lists folders AND files as relative paths;
	-- LC_ALL=C sort puts them in deterministic byte order (locale-dependent
	-- sort would vary between machines); the loop then creates each entry
	-- with its final name, in list order. mkdir for folders; cp -X for
	-- files (-X skips xattrs); touch -r preserves the modification time
	-- (rsync -a did this); printf echoes each entry so the Terminal shows
	-- live progress like rsync -av did. User paths enter the payload ONLY
	-- via quoted form / shell variables — never hand-rolled quoting.
	set buildListCmd to "SRC=" & quoted form of srcPath & "
TGT=" & quoted form of tgtPath & "
LIST=" & quoted form of fileList & "
cd \"$SRC\" || exit 1
find . -mindepth 1 \\( " & exArgs & " \\) -prune -o \\( -type f -o -type d \\) -print | LC_ALL=C sort > \"$LIST\" || exit 1
echo \"Ordered write list created (folders + files)\"
count=$(wc -l < \"$LIST\")
echo \"Entries to write: $count\"
while IFS= read -r p; do
  rel=\"${p#./}\"
  printf '%s\\n' \"$rel\"
  if [ -d \"$p\" ]; then
    mkdir -p \"$TGT/$rel\" || { echo \"FAILED creating folder: $rel\"; exit 1; }
  else
    { cp -X \"$p\" \"$TGT/$rel\" && touch -r \"$p\" \"$TGT/$rel\"; } || { echo \"FAILED copying: $rel\"; exit 1; }
  fi
done < \"$LIST\"
echo \"All entries written in name-sorted order\"
sync
diskutil unmount \"$TGT\"
echo \"DONE\""

	-- Deliver as a file and run it with non-interactive /bin/bash (see
	-- header). tr strips any CR line endings a compiler might store in the
	-- multi-line literal, so bash always sees clean LF-separated lines.
	do shell script "printf '%s\\n' " & quoted form of buildListCmd & " | tr '\\r' '\\n' > " & quoted form of scriptFile
	runTerminal("/bin/bash " & quoted form of scriptFile)
end run

on runTerminal(cmd)
	tell application "Terminal"
		activate
		do script cmd
	end tell
end runTerminal
