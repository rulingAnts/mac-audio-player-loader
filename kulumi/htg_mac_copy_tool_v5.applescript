-- HTG Mac Copy Tool v5 (fixed FAT write-order bug)
--
-- v4 fixed the relative path bug. v5 fixes the play-order bug:
-- v4 already built a name-sorted file list, but then handed it to rsync.
-- Apple's rsync (openrsync) writes every file as a ".name.XXXXXX" temp file
-- and renames it into place; on FAT each rename re-allocates the directory
-- entry FIRST-FIT into slots freed by earlier temp entries, so the final
-- entry order scrambles (name-length dependent — uniform short names can
-- pass by luck). Players follow raw FAT entry order, so playback order broke
-- even though the list was sorted.
--
-- v5 therefore writes every folder and file itself, with its FINAL name, in
-- strict name-sorted order — no temp files, no renames — so each FAT entry
-- is allocated in play order. NOTE: this guarantee only holds on an empty
-- target (use NUKE + Copy, or a freshly formatted volume); entries that
-- already exist on the target keep whatever slot they had.
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

	-- Build exclude args (v5: as a find -prune group instead of v4's
	-- "-not -name" chain, so files INSIDE excluded folders are skipped too —
	-- required now that the writer no longer auto-creates parent folders the
	-- way rsync --files-from did)
	set exArgs to ""
	repeat with e in excludeList
		if exArgs is "" then
			set exArgs to "-name \"" & e & "\""
		else
			set exArgs to exArgs & " -o -name \"" & e & "\""
		end if
	end repeat

	-- Nuke mode
	if buttonChoice = "NUKE + Copy" then
		display dialog "NUKING TARGET in 3 seconds..." giving up after 1
		display dialog "2..." giving up after 1
		display dialog "1..." giving up after 1
		do shell script "rm -rf \"" & tgtPath & "\"/*"
	end if

	-- Create ordered write list using RELATIVE paths
	-- (v5: folders are listed too, not just files — a folder's FAT entry in
	-- its parent is allocated at mkdir time, so folders must be created in
	-- the same name-sorted sequence as everything else. LC_ALL=C makes the
	-- sort plain byte order — deterministic, and machine/locale independent.)
	set fileList to "/tmp/htg_filelist.txt"

	set buildListCmd to "cd \"" & srcPath & "\" || exit 1
TGT=\"" & tgtPath & "\"
find . -mindepth 1 \\( " & exArgs & " \\) -prune -o \\( -type f -o -type d \\) -print | LC_ALL=C sort > " & fileList & "
echo \"Ordered write list created (folders + files)\"
count=$(wc -l < " & fileList & ")
echo \"Entries to write: $count\"
# ORDERED WRITER (replaces v4's rsync): every entry is created with its
# final name, in list order. mkdir for folders; cp -X for files (-X skips
# xattrs); touch -r preserves the modification time (rsync -a did this).
# NEVER swap rsync/ditto/mv back in here — any temp-file-and-rename copier
# re-scrambles the FAT entry order this loop exists to control.
while IFS= read -r p; do
  rel=\"${p#./}\"
  if [ -d \"$p\" ]; then
    mkdir -p \"$TGT/$rel\" || { echo \"FAILED creating folder: $rel\"; exit 1; }
  else
    { cp -X \"$p\" \"$TGT/$rel\" && touch -r \"$p\" \"$TGT/$rel\"; } || { echo \"FAILED copying: $rel\"; exit 1; }
  fi
done < " & fileList & "
echo \"All entries written in name-sorted order\"
sync
diskutil unmount \"" & tgtPath & "\"
echo \"DONE\""

	runTerminal(buildListCmd)
end run

on runTerminal(cmd)
	tell application "Terminal"
		activate
		do script cmd
	end tell
end runTerminal
