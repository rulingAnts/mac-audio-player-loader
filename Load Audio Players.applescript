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

-- Find this file's own folder, then the loader that sits beside it.
set myPosix to POSIX path of (path to me)
set myFolder to do shell script "dirname " & quoted form of myPosix
set loaderPath to myFolder & "/load_content.sh"

-- Safety: refuse to run if the loader isn't next to us (someone moved this file).
if (do shell script "[ -f " & quoted form of loaderPath & " ] && echo yes || echo no") is "no" then
	display alert "Can't find load_content.sh" message "This launcher has to stay in the SAME folder as load_content.sh (the file that does the loading). Put them back in the same folder and press Run again." as critical
	return
end if

-- Open Terminal and run the loader there. `do script` starts it in a fresh
-- Terminal window with a live view of everything (progress bar, prompts,
-- colours) — exactly as if you had typed it yourself. The first time, macOS
-- asks whether Script Editor may control Terminal: click Allow.
tell application "Terminal"
	activate
	do script "clear; /bin/bash " & quoted form of loaderPath
end tell
