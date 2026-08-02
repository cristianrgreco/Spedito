on run arguments
  if (count of arguments) is not 1 then error "Expected the mounted disk name."

  set mountedDiskName to item 1 of arguments

  tell application "Finder"
    tell disk (mountedDiskName as text)
      open

      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set bounds of container window to {180, 140, 840, 580}

      set viewOptions to icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 112
      set text size of viewOptions to 13
      set shows item info of viewOptions to false
      set shows icon preview of viewOptions to true
      set background picture of viewOptions to file ".background:background.png"

      set position of item "Spedito.app" to {180, 240}
      set position of item "Applications" to {480, 240}

      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
