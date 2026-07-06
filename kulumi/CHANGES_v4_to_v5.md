# HTG Mac Copy Tool — changes from v4 to v5

Kulumi's v4 AppleScript (`htgmacv4.scpt`) hit the same field bug this project
fixed on 2026-07-06: files play out of order on the device even though they
are named with correct leading-zero prefixes. This document lists every edit
made in v5 and the reason for each. Nothing else was changed.

## The bug v4 had

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
  if [ -d "$p" ]; then
    mkdir -p "$TGT/$rel" || { echo "FAILED creating folder: $rel"; exit 1; }
  else
    { cp -X "$p" "$TGT/$rel" && touch -r "$p" "$TGT/$rel"; } || { echo "FAILED copying: $rel"; exit 1; }
  fi
done < /tmp/htg_filelist.txt
```

**Why:** every folder and file is now created **with its final name, in list
order — no temp files, no renames** — so each FAT directory entry is
allocated in exactly the play order the sorted list defines. `cp -X` skips
extended attributes (fewer `._*` AppleDouble leftovers on the volume);
`touch -r` preserves each file's modification time, which `rsync -a` used to
do. Any failure aborts immediately with the offending path instead of
rsync's continue-and-summarize behavior, so a half-written (and therefore
wrongly-ordered) volume can't masquerade as success.

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
`.Trashes` were copied by rsync, which silently created their parent dirs).

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
players and this tool's own expectations use, and it varies from Mac to Mac.
`LC_ALL=C` pins the sort to deterministic byte order, matching this repo's
`load_content.sh`.

## Minor hardening (behavior-neutral)

- `cd "$SRC" || exit 1` — if the `cd` fails, abort instead of running the
  writer against the wrong directory.
- The target path is assigned once to a shell variable `TGT` instead of
  being spliced into the loop three times (same value, fewer quoting traps).
- Progress echoes reworded ("Entries to write" instead of "Files to copy")
  since the list now counts folders too.

## Deliberately NOT changed

- The dialogs, button flow, NUKE + Copy countdown, and `rm -rf "$TGT"/*`
  nuke behavior.
- The exclude pattern list (same nine patterns).
- The Terminal-window execution model (`runTerminal` handler).
- The list file location (`/tmp/htg_filelist.txt`), `sync`, and the final
  `diskutil unmount`.

## Caveat that existed in v4 and still exists in v5

The order guarantee only holds for entries **created by this run** — a FAT
entry that already exists on the target keeps whatever slot it had, and
overwriting a file in place does not move its entry. For guaranteed play
order, load onto an empty volume (use **NUKE + Copy** or a freshly formatted
device). Note `rm -rf "$TGT"/*` does not remove dot-entries (e.g.
`.Spotlight-V100`); those occupy early directory slots but are invisible to
the player. This matches v4's nuke behavior and was left as-is.

## Verification performed

The exact shell block the AppleScript generates was reproduced verbatim and
run against a test tree containing varied-length names, spaces, the
`001 Foo` / `001 Foo Bar` prefix case, and populated excluded folders
(`.Trashes`, `dir_nt`) — with files deliberately created on the source disk
in non-alphabetical order:

- write list is strictly `LC_ALL=C`-sorted, folders included, and creation
  follows it 1:1 (no temp names, no renames) ✅
- source readdir order provably ignored ✅
- all nine exclude patterns absent from list and target, including contents
  of excluded folders ✅
- file contents and modification times preserved ✅
- `bash -n` clean; runs identically under bash and strict-POSIX dash (so
  macOS zsh, the default `do script` shell, is safe) ✅

Not yet verified on real hardware: a raw-FAT-table read of a device loaded
by v5 (this environment has no macOS/FAT volume). The mechanism is identical
to the one already proven for `load_content.sh` on 2026-07-06.

## Using the new file

`htg_mac_copy_tool_v5.applescript` is plain-text AppleScript source. Open it
in Script Editor and run it directly, or File → Export → File Format:
"Script" to produce a compiled `.scpt` like the original.
