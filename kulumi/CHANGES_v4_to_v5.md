# HTG Mac Copy Tool — changes from v4 to v5

Kulumi's v4 AppleScript (`htgmacv4.scpt`) has the play-order bug this project
fixed in its own loader on 2026-07-06: files play out of order on the device
even when they are named with correct leading-zero prefixes. This document
lists what v5 changes and why.

## The bug v4 has

FAT players play files in **raw FAT directory-entry order**, not name order.
v4 already did the right first half — it built a name-sorted file list:

```sh
find . -type f <excludes> | sort > /tmp/htg_filelist.txt
```

…but then handed that list to rsync:

```sh
rsync -av --files-from="/tmp/htg_filelist.txt" "$SRC" "$TGT"
```

Apple's rsync (openrsync) writes every file as a `.name.XXXXXX` **temp file
and then renames it into place**. On FAT, each rename re-allocates the
directory entry *first-fit* into slots freed by earlier temp entries, so the
final entry order comes out scrambled — dependent on filename lengths, which
is why uniform short names can pass by pure luck while varied-length names
fail. The sorted list was correct; rsync betrayed it. (Root cause verified
against raw FAT directory tables on 2026-07-06; see this repo's TECHNICAL
docs and the `load_content.sh` fix in commit 145c066.)

## Change 1 — replace rsync with an ordered in-place writer (the core fix)

**v4:**
```sh
rsync -av --files-from="/tmp/htg_filelist.txt" "$SRC" "$TGT"
```

**v5:**
```sh
while IFS= read -r p; do
  rel="${p#./}"
  printf '%s\n' "$rel"
  if [ -d "$p" ]; then
    mkdir -p "$TGT/$rel" || { echo "FAILED creating folder: $rel"; exit 1; }
  else
    { cp -X "$p" "$TGT/$rel" && touch -r "$p" "$TGT/$rel"; } || { echo "FAILED copying: $rel"; exit 1; }
  fi
done < "$LIST"
```

**Why:** every folder and file is now created **with its final name, in list
order — no temp files, no renames** — so each FAT directory entry is
allocated in exactly the play order the sorted list defines. `cp -X` skips
extended attributes (fewer `._*` AppleDouble leftovers on the volume);
`touch -r` preserves each file's modification time, which `rsync -a` used to
do; the `printf` echoes each entry so the Terminal window shows the same
live per-file progress `rsync -av` gave. Any failure aborts immediately with
the offending path instead of rsync's continue-and-summarize behavior, so a
half-written (and therefore wrongly-ordered) volume can't masquerade as
success.

**Never swap rsync/ditto/mv back into this loop** — any temp-file-and-rename
copier re-scrambles the FAT entry order the loop exists to control.

## Change 2 — folders are enumerated and sorted too, not just files

**v4:** `find . -type f …` (directories were created implicitly by rsync)

**v5:** `find . -mindepth 1 … \( -type f -o -type d \) -print`

**Why:** a folder's FAT entry in its *parent* directory is allocated at
`mkdir` time, so folders must be created in the same name-sorted sequence as
everything else — the play order of folders matters exactly as much as the
play order of files. This also fixes a subtle prefix case: with a files-only
list, `001 Foo Bar/track.mp3` sorts *before* `001 Foo/track.mp3` (a space
sorts before `/`), so the folder `001 Foo Bar` would be created before
`001 Foo` — out of name order. With the folders themselves in the list,
`001 Foo` < `001 Foo Bar` and they are created correctly.

## Change 3 — exclude list applied as a `find -prune` group

**v4:** ` -not -name "X"` chained per pattern — this hid the excluded entry
itself but still listed files *inside* excluded folders (e.g. files in
`.Trashes` were copied, with rsync silently creating their parent dirs).

**v5:** `\( -name "X" -o -name "Y" … \) -prune -o …` — an excluded folder is
skipped *with its entire contents*.

**Why:** two reasons. It is what the exclude list clearly intends (excluding
`.Trashes` should exclude the trash, not just the folder's name). And it is
now required for correctness: the v5 writer creates parents explicitly from
the list, so a file whose excluded parent was never listed would have
nowhere to land. The exclude *patterns themselves are unchanged*.

## Change 4 — `sort` → `LC_ALL=C sort`

**Why:** plain `sort` obeys the machine's locale (e.g. `en_US.UTF-8`), which
case-folds and skips punctuation — a different order than the byte order FAT
players use, and it varies from Mac to Mac. `LC_ALL=C` pins the sort to
deterministic byte order, matching this repo's `load_content.sh`.

## Change 5 — the command runs as a script file, not as typed keystrokes

**v4:** passed the whole multi-line shell command to Terminal's `do script`,
which *types it into the user's interactive shell* (zsh by default on modern
macOS).

**v5:** writes the command to a private temp file and Terminal runs one
short line: `/bin/bash <file>`.

**Why:** an interactive shell parses typed text differently from a script —
`#` is not a comment in interactive zsh (`INTERACTIVE_COMMENTS` is off by
default), `!` history expansion is live, and the user's aliases apply (a
common `alias cp='cp -i'` would stall a copy on overwrite prompts). v4's
multi-line payload only survived this by luck of containing no hazardous
characters; delivering a multi-line program as keystrokes is inherently
fragile. Non-interactive `/bin/bash` running a file has none of those
behaviors, and the `exit 1` error guards end the script rather than the
user's terminal session. The file is written via AppleScript's
`quoted form of` (byte-exact for any content) with CR line endings
normalized to LF.

## Change 6 — user-chosen paths pass through `quoted form of`

**v4:** spliced raw paths into hand-rolled double quotes:
`"rm -rf \"" & tgtPath & "\"/*"`, `rsync … "` & srcPath & `" "` & tgtPath & `"`.

**v5:** every user path enters the shell via AppleScript's `quoted form of`
and is referenced through shell variables (`"$SRC"`, `"$TGT"`).

**Why:** inside shell double quotes, `$`, backticks, and `"` are live
syntax, and all are legal in macOS folder names and FAT volume names.
Concrete failures with v4-style splicing: a target volume named `MUSIC$2`
silently expands to `/Volumes/MUSIC/` — the copy (and with NUKE, the
**rm -rf**) hits a *different volume* and reports success; a folder named
`12" Singles` re-tokenizes the whole command; a name containing `$(…)` or
backticks executes it. `quoted form of` delivers any name literally.

## Change 7 — NUKE also clears hidden dot-entries

**v4:** `rm -rf "$TGT"/*`

**v5:** `rm -rf "$TGT"/* "$TGT"/.[!.]* "$TGT"/..?*`

**Why:** the shell glob `*` skips dot-names, so v4's nuke left `._*`
AppleDouble files (the very junk the exclude list keeps off the device),
`.DS_Store`, `.Spotlight-V100`, etc. on the "nuked" volume. Beyond hygiene,
this matters for play order: leftover entries fragment the FAT directory,
and first-fit allocation into the gaps between them can reorder the new
entries (varied-length names need different numbers of contiguous LFN
slots). Emptying the root completely is part of the order guarantee. The
two extra globs cover dot-names without ever matching `.` or `..`, and
`rm -f` exits 0 when a glob matches nothing.

## Change 8 — private temp directory instead of a fixed `/tmp` name

**v4:** hardcoded `/tmp/htg_filelist.txt` — world-writable, shared across
all local users, so runs can collide and another local account can
pre-create or symlink the path.

**v5:** `mktemp -d /tmp/htg_copy.XXXXXX` gives each run its own 0700
directory holding both the file list and the generated script.

## Deliberately NOT changed

- The dialogs, button flow, and NUKE + Copy countdown.
- The exclude pattern list (same nine patterns).
- The Terminal-window execution model (output still appears live in a
  Terminal window) and the final `sync` + `diskutil unmount`.

## Caveat

The order guarantee only holds for entries **created by this run into an
empty directory** — a FAT entry that already exists keeps its slot, and
overwriting a file in place does not move its entry. For guaranteed play
order, load onto an empty volume: use **NUKE + Copy** (which now truly
empties the root) or a freshly formatted device.

## Verification performed

The exact shell text the AppleScript generates was reproduced verbatim
(including the `quoted form of` delivery, for both LF and CR compiled string
literals — byte-identical script file both ways) and exercised against test
trees with varied-length names, spaces, the `001 Foo` / `001 Foo Bar` prefix
case, populated excluded folders, and hostile path names
(`Seth's 12" Mix $HOME `` `id` `` $(touch PWNED)`, `MUSIC$2`):

- creation follows the strictly `LC_ALL=C`-sorted list 1:1, folders
  included; source readdir order provably ignored ✅
- hostile characters in source/target paths are handled literally — correct
  tree copied, no misdirected writes, no command execution ✅
- all nine exclude patterns absent from list and target, including contents
  of excluded folders ✅
- file contents and modification times preserved; per-entry progress printed ✅
- NUKE leaves the target completely empty (dot-entries included) and exits
  cleanly on an already-empty target ✅
- the single line handed to Terminal runs correctly in an interactive zsh
  configured with hostile aliases (`cp='cp -i'`, sabotaged `mkdir`/`find`);
  payload also passes under bash and strict-POSIX dash ✅
- separately, the first-fit reorder mechanism was reproduced on a real FAT
  filesystem image, confirming both the rsync failure mode and that leftover
  directory entries can reorder subsequent writes ✅

Not verified here: a raw-FAT-table read of a device loaded by v5 on real
hardware (this environment has no macOS). The write mechanism is identical
to the one proven on-device for this repo's `load_content.sh`.

## Using the new file

`htg_mac_copy_tool_v5.applescript` is plain-text AppleScript source. Open it
in Script Editor and run it directly, or File → Export → File Format:
"Script" to produce a compiled `.scpt` like the original.
