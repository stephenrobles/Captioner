#!/bin/zsh
# capture-duo.sh <out.png> <media folder> "<video name>" <seek seconds> [sheet]
# Launches the Debug build on the "iPhone Duo (Captioner)" simulator with the video and its
# word-level SRT (<media folder>/<video name>.mp4 + .srt), opens the editor parked at <seek>,
# then moves the app to a hidden 951x669 pt "Resizable" display (the unfolded inner display's
# size; the fold itself can't be scripted) and saves a 2853x2007 capture.
# Env: STYLE=<preset id>, WATERMARK=/path/logo.png, SIM=<udid>. Sheet: style|position|captions|watermark|gallery.
# INNER=1: the simulator is already unfolded in Device Hub, so capture the real inner display
# (with its status bar) instead of the hidden Resizable one.
set -e
U=${SIM:-EDC71188-CED7-47BD-93C0-8056DD3A7F77}; OUT=$1; MEDIA=$2; VIDEO=$3; SEEK=$4; SHEET=$5
xcrun simctl terminate $U fm.beard.Captioner >/dev/null 2>&1 || true
C=$(xcrun simctl get_app_container $U fm.beard.Captioner data); rm -rf "$C/Documents/Imports" "$C/Documents/Exports"
SIMCTL_CHILD_CAPTIONER_DEBUG_OPEN="$MEDIA/$VIDEO.mp4" SIMCTL_CHILD_CAPTIONER_DEBUG_SUBTITLES="$MEDIA/$VIDEO.srt" \
SIMCTL_CHILD_CAPTIONER_DEBUG_EDIT=1 SIMCTL_CHILD_CAPTIONER_DEBUG_STILL=1 SIMCTL_CHILD_CAPTIONER_DEBUG_SEEK=$SEEK \
SIMCTL_CHILD_CAPTIONER_DEBUG_SHEET=$SHEET SIMCTL_CHILD_CAPTIONER_DEBUG_STYLE=$STYLE SIMCTL_CHILD_CAPTIONER_DEBUG_WATERMARK=$WATERMARK \
xcrun simctl launch $U fm.beard.Captioner >/dev/null
sleep 9
if [[ -n "$INNER" ]]; then
  xcrun simctl io $U screenshot --display=primary-1 --type=png "$OUT" >/dev/null
  echo "captured $OUT (inner display)"; exit 0
fi
xcrun devicectl device appResize start --device $U --preferred-size 951x669 >/dev/null 2>&1 &
RP=$!; sleep 6
RID=$(xcrun devicectl device info displays --device $U 2>/dev/null | awk '/Resizable/{f=1} f&&/uniqueId/{print $NF; exit}')
xcrun devicectl device capture screenshot --device $U --display-unique-id $RID --destination "$OUT" -q
kill $RP 2>/dev/null; wait $RP 2>/dev/null || true
echo "captured $OUT"
