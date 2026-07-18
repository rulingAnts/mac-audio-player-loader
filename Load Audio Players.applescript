-- ============================================================
--   AUDIO  PLAYER  LOADER
--
--   ▶  TO START:  click the  RUN  button above
--      (the ► play-triangle in the toolbar, or press  Command-R ).
--
--   A Terminal window opens and does the work — just answer the
--   questions there. You can close THIS window once it starts.
--
--   Keep this file in the same folder as  load_content.sh .
--   When you press Run, the loader asks you to choose your
--   content folder — so your audio can live anywhere.
--
--   (This is just an "ignition key": it launches the real
--    loader, load_content.sh, in Terminal. Nothing here erases
--    anything — the loader asks you before touching any device.)
-- ============================================================

-- Find this file's own folder, then the loader. In the download (.dmg) the
-- loader lives in a hidden ".loader" sub-folder, so the window shows only THIS
-- launcher and non-technical users can't pick the wrong file. When the repo is
-- cloned it sits right beside us instead — so check both, preferring whichever
-- exists (beside first, for developers; then the hidden folder, for the .dmg).
set myPosix to POSIX path of (path to me)
set myFolder to do shell script "dirname " & quoted form of myPosix
set besidePath to myFolder & "/load_content.sh"
set hiddenPath to myFolder & "/.loader/load_content.sh"

if (do shell script "[ -f " & quoted form of besidePath & " ] && echo yes || echo no") is "yes" then
	set loaderPath to besidePath
else if (do shell script "[ -f " & quoted form of hiddenPath & " ] && echo yes || echo no") is "yes" then
	set loaderPath to hiddenPath
else
	display alert "Can't find load_content.sh" message "This launcher needs load_content.sh — either right beside it, or in a hidden \".loader\" folder next to it (as it ships in the download). Keep this launcher together with its folder and press Run again." as critical
	return
end if

-- Open Terminal and run the loader there. `do script` starts it in a fresh
-- Terminal window with a live view of everything (progress bar, prompts,
-- colours) — exactly as if you had typed it yourself.
--   • `exec` replaces the window's shell with the loader, so when the loader
--     finishes there is NO leftover shell process — the window shows
--     "[Process completed]" and quitting Terminal (Cmd-Q) never pops the
--     "terminate the running process?" warning.
--   • `activate` comes AFTER `do script` so the new window is brought to the
--     FRONT (activating first would let Script Editor take focus back).
-- Script Editor is left open — just close it (Cmd-Q) when you're done. The
-- first time, macOS asks whether Script Editor may control Terminal: Allow.
tell application "Terminal"
	do script "clear; exec /bin/bash " & quoted form of loaderPath
	activate
end tell
