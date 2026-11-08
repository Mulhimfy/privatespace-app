#!/usr/bin/env bash
# Drives Private Space on an emulator through a REAL work profile: Android's own setup screens,
# copying apps in, hiding one, hiding the whole space, opening an app inside, the PIN lock and
# deleting the space. Taps go by the labels the app exposes to accessibility (uiautomator).
#   run.sh <apk> <out dir>
APK=$1
OUT=$2
PKG=com.privatespace.app
mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$*" | tee -a "$LOG"; }
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; }

adb wait-for-device
adb logcat -v time > "$OUT/logcat_live.txt" 2>&1 &
adb shell settings put global hide_error_dialogs 1
adb shell input keyevent KEYCODE_HOME
sleep 15
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
for k in window_animation_scale transition_animation_scale animator_duration_scale; do adb shell settings put global $k 0; done
# The emulator's vibrator HAL can take the whole emulator down: touch feedback off (the app follows it).
adb shell settings put system haptic_feedback_enabled 0
adb shell settings put system haptic_feedback_intensity 0 2>/dev/null || true
SDK=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
say "sdk $SDK, screen $(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)"
adb install -r "$APK" | tail -1 | tee -a "$LOG"

alive() { [ "$(timeout 10 adb get-state 2>/dev/null)" = device ]; }
gone() { say "FAIL emulator went away; stopping here"; adb logcat -d -v time > "$OUT/logcat.txt" 2>&1; exit 0; }
shot() {
  sleep "${2:-0}"
  alive || gone
  timeout 20 adb exec-out screencap -p > "$OUT/$1.png"
  say "shot $1 ($(stat -c %s "$OUT/$1.png") bytes)"
}
dump() {
  rm -f "$OUT/ui.xml"
  timeout 25 adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  timeout 10 adb exec-out cat /sdcard/ui.xml > "$OUT/ui.xml" 2>/dev/null
}
# find "x y" of the first node matching: mode '' = label contains $1, 'exact' = a word of our app's
# label equals $1, 'full' = the node's text/description is exactly $1, 'any' = one of |-separated
# labels, exact, in any app (Android's own screens).
find_node() {
  python3 - "$1" "$OUT/ui.xml" "${2:-}" "$PKG" <<'PY'
import re, sys
want, path, mode, pkg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    xml = open(path, encoding='utf-8', errors='ignore').read()
except OSError:
    sys.exit()
wants = [w.strip().lower() for w in want.split('|')]
for node in re.findall(r'<node [^>]*>', xml):
    t = re.search(r' text="([^"]*)"', node); d = re.search(r' content-desc="([^"]*)"', node)
    tt = (t.group(1) if t else ''); dd = (d.group(1) if d else '')
    label = (tt + ' ' + dd).replace('&#10;', ' ').replace('&amp;', '&')
    p = re.search(r' package="([^"]*)"', node)
    mine = p is not None and p.group(1) == pkg
    def parts(f):
        return [x.strip().lower() for x in f.replace('&amp;', '&').split('&#10;') if x.strip()]
    if mode == 'exact':
        hit = mine and want in label.split()
    elif mode == 'full':
        hit = mine and any(parts(f) and all(x == want.lower() for x in parts(f)) for f in (tt, dd))
    elif mode == 'any':
        named = any(parts(f) and parts(f)[0] in wants for f in (tt, dd))
        tappable = 'clickable="true"' in node or re.search(r'class="android.widget.(Button|TextView)"', node)
        hit = (not mine) and named and bool(tappable)
    else:
        hit = want.lower() in label.lower()
    if hit:
        m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            if x2 - x1 < 4 or y2 - y1 < 4:
                continue
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
PY
}
tap() {
  local want=$1 tries=${2:-4} mode=${3:-}
  alive || gone
  for _ in $(seq "$tries"); do
    dump
    local b
    b=$(find_node "$want" "$mode")
    if [ -n "$b" ]; then
      adb shell input tap $b
      say "tap '$want' at $b"
      return 0
    fi
    sleep 2
  done
  say "NOT FOUND: '$want'"
  NF=$((${NF:-0} + 1)); cp "$OUT/ui.xml" "$OUT/notfound_${NF}.xml" 2>/dev/null || true
  return 1
}
hold() {
  dump
  local b
  b=$(find_node "$1" "${2:-}")
  [ -z "$b" ] && { say "NOT FOUND (hold): '$1'"; return 1; }
  # shellcheck disable=SC2086
  set -- $b
  adb shell input swipe "$1" "$2" "$1" "$2" 1100
  say "hold at $1 $2"
}
seen() { dump; [ -n "$(find_node "$1" "${2:-}")" ]; }
profile_id() { adb shell pm list users | grep -v '{0:' | grep -oE 'UserInfo\{[0-9]+' | grep -oE '[0-9]+' | head -1; }
hidden_in() { adb shell dumpsys package "$2" | tr -d '\r' | grep -E "^ +User $1:" | grep -oE 'hidden=(true|false)' | head -1; }

# ---- 1. welcome ----
adb shell am start -W -n $PKG/.MainActivity | tail -1 | tee -a "$LOG"
shot 01_welcome 8
tap "Create my space" 4 full

# ---- 2. Android's own work-profile setup ----
for i in $(seq 1 14); do
  sleep 4
  if seen "Your space is ready" || seen "Add apps" full; then break; fi
  shot "02_setup_$i"
  tap "Accept & continue|Accept and continue|Agree and continue|Continue|Next|Accept|Agree|I agree|Set up|OK|Got it|Done|Start" 1 any || true
done
ID=$(profile_id)
if [ -n "$ID" ]; then
  pass "work profile created by Android's setup (user $ID)"
else
  fail "setup screens did not create a profile; making one over adb to test the rest"
  adb shell input keyevent KEYCODE_BACK; sleep 1
  ID=$(adb shell pm create-user --profileOf 0 --managed "Private Space" | grep -oE '[0-9]+$')
  adb shell am start-user "$ID"
  adb shell pm install-existing --user "$ID" $PKG
  adb shell dpm set-profile-owner --user "$ID" $PKG/.ProfileAdmin | tee -a "$LOG"
  sleep 2
  # what Android does at the end of its own setup: start the admin's "provisioning finished" screen in the profile
  adb shell am start --user "$ID" -n $PKG/.ProvisionedActivity | tail -1 | tee -a "$LOG"
  sleep 4
  adb shell am force-stop $PKG
  adb shell am start -W -n $PKG/.MainActivity | tail -1
  sleep 6
fi
adb shell dumpsys device_policy > "$OUT/device_policy.txt" 2>&1
sleep 5
# Diagnostics: is the control door enabled in the profile, and does the personal side see a forwarder?
adb shell pm query-activities --user "$ID" -a com.privatespace.app.action.CONTROL -c android.intent.category.DEFAULT > "$OUT/q_profile.txt" 2>&1
adb shell pm query-activities --user 0 -a com.privatespace.app.action.CONTROL -c android.intent.category.DEFAULT > "$OUT/q_personal.txt" 2>&1
adb shell dumpsys package com.privatespace.app > "$OUT/pkg.txt" 2>&1
adb shell dumpsys package > "$OUT/pkg_all.txt" 2>&1
say "profile door: $(grep -c ControlActivity "$OUT/q_profile.txt") · personal matches: $(grep -cE "name=|packageName=" "$OUT/q_personal.txt")"
grep -q "ControlActivity" "$OUT/q_profile.txt" && pass "control door enabled in the profile" || fail "control door not enabled in the profile"
grep -qiE "IntentForwarder|forward" "$OUT/q_personal.txt" && pass "personal side sees the cross-profile forwarder" || fail "no cross-profile forwarder on the personal side"
# Private Space should be back in front after Android's setup; if not, note it and open it.
adb shell dumpsys activity activities | grep -m1 -E "topResumedActivity|mResumedActivity" | tee -a "$LOG" | grep -q privatespace && pass "back in Private Space after setup" || { fail "not back in Private Space after setup"; adb shell am start -W -n $PKG/.MainActivity | tail -1; sleep 5; }
grep -q "com.privatespace.app" "$OUT/device_policy.txt" && pass "profile owner is Private Space" || fail "profile owner not found"
adb shell pm list packages --user "$ID" > "$OUT/profile_packages_start.txt"
shot 03_ready 3

# ---- 3. add apps ----
tap "Add apps" 4 full
shot 04_add_apps 4
PICKED=()
for name in Clock Calendar Contacts Files Chrome Camera; do
  [ ${#PICKED[@]} -ge 2 ] && break
  if tap "$name" 1 full; then PICKED+=("$name"); fi
done
say "picked ${PICKED[*]}"
shot 05_picked 1
tap "Add 2 apps" 3 full || tap "Add 1 app" 2 full
sleep 12
shot 06_home 2
adb shell pm list packages --user "$ID" > "$OUT/profile_packages_after_add.txt"
APP1=${PICKED[0]:-Clock}
seen "$APP1" full && pass "'$APP1' shows in the space" || fail "'$APP1' missing from the space grid"
case "$APP1" in
  Clock) PKG1=com.google.android.deskclock;; Calendar) PKG1=com.google.android.calendar;; Contacts) PKG1=com.google.android.contacts;;
  Files) PKG1=com.google.android.documentsui;; Chrome) PKG1=com.android.chrome;; *) PKG1=com.android.camera2;;
esac
say "checking package $PKG1"

# ---- 4. hide one app ----
hold "$APP1" full
shot 07_app_sheet 2
tap "Hide this app" 3 full
sleep 5
H=$(hidden_in "$ID" "$PKG1"); say "after hide one: $PKG1 $H"
adb shell input keyevent KEYCODE_BACK
shot 08_one_hidden 2

# ---- 5. hide the whole space ----
tap "Hide space" 3 full
sleep 6
shot 09_space_hidden 1
for p in $(adb shell pm list packages -u --user "$ID" | tr -d '\r' | sed 's/package://' | grep -iE "deskclock|calendar|contacts|documentsui|chrome|camera"); do say "  $p $(hidden_in "$ID" "$p")"; done
[ "$(hidden_in "$ID" "$PKG1")" = "hidden=true" ] && pass "space hidden: $PKG1 hidden in the profile" || fail "space hide did not hide $PKG1"
tap "Show space" 3 full || tap "Hide space" 3 full
sleep 6
[ "$(hidden_in "$ID" "$PKG1")" = "hidden=false" ] && pass "space shown again" || fail "space show did not unhide $PKG1"
shot 10_space_visible 1

# ---- 6. open an app inside the space ----
tap "$APP1" 3 full
sleep 6
adb shell dumpsys activity activities | tr -d '\r' | grep -m2 -E "mResumedActivity|topResumedActivity" | tee -a "$LOG"
shot 11_app_in_space 1
adb shell dumpsys activity activities | grep -m1 -E "mResumedActivity|topResumedActivity" | grep -q " u$ID " && pass "app opened inside the profile (u$ID)" || say "CHECK resumed activity above"
adb shell input keyevent KEYCODE_HOME
sleep 2
adb shell am start -W -n $PKG/.MainActivity | tail -1
sleep 4

# ---- 7. PIN lock ----
tap "Settings" 3 full
shot 12_settings 3
tap "App lock" 3 full
sleep 2
shot 13_pin_setup 1
for d in 1 2 3 4; do tap "$d" 2 full; done
tap "Continue" 2 full
sleep 1
for d in 1 2 3 4; do tap "$d" 2 full; done
sleep 3
if seen "Use fingerprint or face" full; then tap "Cancel" 2 full; fi
shot 14_pin_set 2
adb shell input keyevent KEYCODE_BACK
sleep 2
tap "Lock now" 3 full
shot 15_locked 2
for d in 1 2 3 4; do tap "$d" 2 full; done
sleep 3
seen "Hide space" full && pass "PIN lock opens with the right PIN" || fail "still locked after PIN"
shot 16_unlocked 1

# ---- 8. delete the space ----
tap "Settings" 3 full
sleep 2
adb shell input swipe 540 1900 540 500 300
sleep 1
adb shell input swipe 540 1900 540 500 300
sleep 2
tap "Delete space" 3 full
sleep 2
shot 17_delete_confirm 1
tap "Delete space" 3 full
sleep 15
shot 18_after_delete 2
[ -z "$(profile_id)" ] && pass "space deleted (no profile left)" || fail "profile still there after delete"
adb shell pm list users | tee -a "$LOG"

adb logcat -d -v time > "$OUT/logcat.txt" 2>&1
grep -E "PrivateSpace|AndroidRuntime|FATAL" "$OUT/logcat.txt" | head -120 > "$OUT/errors.txt" || true
say "done"
