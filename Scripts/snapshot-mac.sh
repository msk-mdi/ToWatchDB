#!/bin/zsh
# Debug visual pass on macOS: runs the app in snapshot mode and captures each screen's window with
# screencapture (only the app's own window), so materials like the sidebar render correctly.
# Extra arguments go to the app, e.g. `Scripts/snapshot-mac.sh -accentColor green -navigationLayout topBar`.
set -e
APP=${APP:-build/DerivedData/Build/Products/Debug/ToWatchDB.app/Contents/MacOS/ToWatchDB}
DIR=$HOME/Library/Containers/com.mehdi.towatchdb/Data/tmp/snap
rm -rf $DIR
$APP -UISnapshotDir $DIR "$@" >/dev/null 2>&1 &
PID=$!
typeset -A seen
while kill -0 $PID 2>/dev/null; do
  for wid in $DIR/*.wid(N); do
    name=${wid:t:r}
    [[ -n ${seen[$name]} ]] && continue
    seen[$name]=1
    sleep 0.3
    screencapture -x -o -l $(cat $wid) $DIR/$name-window.png 2>/dev/null || true
  done
  sleep 0.2
done
echo $DIR
