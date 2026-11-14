#!/usr/bin/env bash
# Debounced lid-switch handler for the Z13.
#
# On this machine the "lid" is the detachable keyboard cover, so accidental
# close + immediate reopen is a NORMAL event. logind and PowerDevil act on
# the raw switch instantly: the reopen lands as a pending wakeup during the
# s2idle entry, the entry aborts, and the instant re-entry races amdgpu into
# a hard wedge (2026-06-12 00:18, wallpaper-frozen, power-cycle needed) —
# even with pm_async=0 and the 2s pre-suspend settle.
#
# 2026-11-14 POLICY CHANGE — lid-close now LOCKS + BLANKS, it no longer
# sleeps.  On this amdgpu machine the s2idle transition is unreliable (it
# aborts *after* the screen-off prep, leaving an awake-but-locked machine)
# and hibernate is broken (image write fails with ENOMEM).  So instead of
# racing a broken sleep transition, lid-close locks the KDE session and
# blanks the display.  No sleep is attempted, so there is nothing to race
# and the "screen off -> lock screen -> still awake" dance is gone.  The
# machine stays fully awake while "closed" (fine on AC; on battery this
# drains the battery — accepted trade-off, 2026-11-14).  Lid-open wakes the
# display; the user unlocks the lock screen manually (that is the "unlock"
# half of the flow).
#
# Debounce is kept: a reopen inside DEBOUNCE_SEC is a complete no-op, so an
# accidental flip never locks the session.
#
# Requires that nobody else acts on the lid:
#   - logind drop-in: HandleLidSwitch=ignore (takes effect on reboot;
#     NEVER restart logind live — see project notes)
#   - PowerDevil: "When laptop lid is closed" = "Do nothing" (both profiles)

LID_STATE=/proc/acpi/button/lid/LID/state
DEBOUNCE_SEC=3
POLL_SEC=1

# ── Resolve the active graphical user + Wayland session ─────────────────────
# The original scripts hardcoded a username that no longer exists on this
# machine (so every user-facing action failed silently).  Resolve the user
# dynamically instead, with a sane fallback for this single-user box.
# Sets: R_USER R_UID R_XDG R_WL R_ENV
_resolve_user() {
  R_USER=$(loginctl list-sessions --no-legend 2>/dev/null \
           | awk '($4=="seat0" || $6=="user"){ print $3; exit }')
  [ -z "$R_USER" ] && R_USER=${SUDO_USER:-tommy}
  R_UID=$(id -u "$R_USER" 2>/dev/null || echo "")
  R_XDG="/run/user/${R_UID}"
  R_WL=""
  if [ -n "$R_UID" ]; then
    for _w in wayland-0 wayland-1 wayland-2 wayland-3 wayland-4; do
      [ -S "${R_XDG}/${_w}" ] && R_WL="$_w" && break
    done
  fi
  R_ENV="XDG_RUNTIME_DIR=${R_XDG} DBUS_SESSION_BUS_ADDRESS=unix:path=${R_XDG}/bus"
  [ -n "$R_WL" ] && R_ENV="${R_ENV} WAYLAND_DISPLAY=${R_WL}"
  return 0
}

# Live KDE ScreenSaver service on this Plasma 6 session (org.kde.ScreenSaver
# does NOT exist here — calls to it failed silently).  This one has Lock(),
# SetActive(bool) and SimulateUserActivity().
_SCREENSAYER_SVC=org.freedesktop.ScreenSaver

# Lid-close action: lock the KDE session + blank the display.  No sleep.
_lock_blank() {
  _resolve_user
  if [ -n "$R_UID" ] && [ -S "${R_XDG}/bus" ]; then
    echo "lid-watch: lid closed >= ${DEBOUNCE_SEC}s — locking + blanking (user=$R_USER, no sleep)"
    sudo -u "$R_USER" env $R_ENV \
      qdbus6 "$_SCREENSAYER_SVC" /ScreenSaver Lock 2>/dev/null \
      || echo "lid-watch: Lock() failed (session gone?)"
    # Blank the display (KDE DPMS will keep it off); non-fatal if it no-ops.
    sudo -u "$R_USER" env $R_ENV \
      qdbus6 "$_SCREENSAYER_SVC" /ScreenSaver SetActive true 2>/dev/null || true
  else
    echo "lid-watch: no active user session found — falling back to suspend"
    systemctl suspend || echo "lid-watch: suspend request failed"
  fi
}

# Lid-open action: wake the display.  The session stays LOCKED — the user
# unlocks the lock screen manually (that is the "unlock" half of the flow).
_wake_display() {
  _resolve_user
  [ -z "$R_UID" ] && return 0
  echo "lid-watch: lid reopened — waking display (user=$R_USER)"
  sudo -u "$R_USER" env $R_ENV \
    qdbus6 "$_SCREENSAYER_SVC" /ScreenSaver SimulateUserActivity 2>/dev/null || true
}

closed_since=""
lid_locked=0   # set when we locked for a closed-lid episode; cleared on reopen
while sleep "$POLL_SEC"; do
  state=$(awk '{print $2}' "$LID_STATE" 2>/dev/null) || continue
  if [ "$state" = "closed" ]; then
    # Already locked for this closed-lid episode: nothing to do while the lid
    # stays closed (avoids re-lock + log spam on every poll).
    [ "$lid_locked" = "1" ] && continue
    now=$(date +%s)
    if [ -z "$closed_since" ]; then
      closed_since=$now
      echo "lid-watch: lid closed, debouncing ${DEBOUNCE_SEC}s"
      continue
    fi
    if [ $(( now - closed_since )) -ge "$DEBOUNCE_SEC" ]; then
      # Stand down while any sleep cycle is in flight: closing the lid over a
      # running manual hibernate must not inject a competing action.  (Kept
      # for safety; lid-close itself no longer sleeps.)
      if [ -f /run/z13-was-hibernated ] \
         || [ -f /run/z13-hibernate-pending ] \
         || systemctl list-jobs --no-legend 2>/dev/null | grep -qE 'sleep\.target|suspend\.target|hibernate\.target'; then
        continue
      fi
      closed_since=""
      lid_locked=1
      _lock_blank
      sleep 1
    fi
  else
    if [ -n "$closed_since" ] || [ "$lid_locked" = "1" ]; then
      _wake_display
    fi
    closed_since=""
    lid_locked=0
  fi
done
