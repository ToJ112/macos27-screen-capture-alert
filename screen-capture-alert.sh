#!/bin/bash
# macOS 27 screen-capture reminder policy. MIT licensed.
set -euo pipefail

KEY=forceBypassScreenCaptureAlert
DOMAIN=com.apple.applicationaccess

die() { printf 'Error: %s\n' "$*" >&2; return 1; }
hash_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
read_bool() { /usr/bin/plutil -extract "$KEY" raw -expect bool -o - "$1" 2>/dev/null; }
check_plain_file() { [[ ! -L "$1" && -f "$1" ]] || die "Not a regular, non-symlink file: $1"; }

# These functions also support isolated fixture tests. The CLI below supplies
# fixed system paths and validates their ownership before any mutation.
install_policy() {
    local target=$1 state=$2 staged before=absent root_text mode=644 gid
    [[ ! -L "$target" && ! -L "$state" ]] || die 'Symlinks are refused.'
    if [[ -e "$state" ]]; then
        check_plain_file "$state/installed.sha256"
        [[ -f "$target" && $(hash_file "$target") == "$(cat "$state/installed.sha256")" ]] || die 'Existing installation differs; inspect the backup before changing anything.'
        printf 'Already installed; nothing changed.\n'
        return
    fi
    if [[ -e "$target" ]]; then
        check_plain_file "$target"
        /usr/bin/plutil -lint "$target" >/dev/null
        # A non-dictionary root cannot accept this key; reject it before backup.
        root_text=$(/usr/libexec/PlistBuddy -c Print "$target")
        [[ "$root_text" == 'Dict {'* ]] || die 'Existing preferences root is not a dictionary.'
        if [[ $(read_bool "$target" || true) == true ]]; then
            printf 'Policy is already true outside this script. No ownership or changes claimed.\n'
            return
        fi
        before=$(hash_file "$target")
    fi
    /bin/mkdir -m 700 "$state"
    if [[ -e "$target" ]]; then
        /bin/cp -p "$target" "$state/original.plist"
        [[ $(hash_file "$state/original.plist") == "$before" ]] || die 'Preferences changed while being backed up; no replacement performed.'
        /usr/bin/stat -f '%Lp' "$target" > "$state/original.mode"
        /usr/bin/stat -f '%g' "$target" > "$state/original.gid"
        mode=$(cat "$state/original.mode")
        /bin/chmod 600 "$state/original.plist"
    else
        : > "$state/no-original"
    fi
    staged=$(/usr/bin/mktemp "${target}.tmp.XXXXXX")
    if [[ -f "$state/original.plist" ]]; then
        /bin/cp "$state/original.plist" "$staged"
    else
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict/></plist>' > "$staged"
    fi
    if ! /usr/bin/plutil -replace "$KEY" -bool true "$staged" >/dev/null 2>&1; then
        /usr/bin/plutil -insert "$KEY" -bool true "$staged" >/dev/null
    fi
    /usr/bin/plutil -lint "$staged" >/dev/null
    [[ $(read_bool "$staged") == true ]] || die 'Staged policy readback failed.'
    hash_file "$staged" > "$state/installed.sha256"
    /bin/chmod 600 "$state/installed.sha256" "$state"/*
    if [[ "$before" == absent ]]; then
        [[ ! -e "$target" && ! -L "$target" ]] || { /bin/rm "$staged"; die 'Preferences appeared concurrently; no replacement performed.'; }
    else
        [[ -f "$target" && ! -L "$target" && $(hash_file "$target") == "$before" ]] || { /bin/rm "$staged"; die 'Preferences changed concurrently; no replacement performed.'; }
    fi
    if [[ -f "$state/original.gid" ]]; then
        gid=$(cat "$state/original.gid")
        /usr/bin/chgrp "$gid" "$staged"
    fi
    /bin/chmod "$mode" "$staged"
    /bin/mv -f "$staged" "$target"
    printf 'Installed. Backup/receipt: %s\nRun status as the target user; forced, value and valid must all be true.\nNo service was restarted.\n' "$state"
}

uninstall_policy() {
    local target=$1 state=$2 staged saved
    [[ -d "$state" && ! -L "$state" ]] || die 'No installation receipt found; refusing to remove an externally managed policy.'
    check_plain_file "$state/installed.sha256"
    check_plain_file "$target"
    [[ $(hash_file "$target") == "$(cat "$state/installed.sha256")" ]] || die 'Preferences changed after installation. Refusing to overwrite them; merge the backup manually.'
    saved="${state}.removed-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
    [[ ! -e "$saved" && ! -L "$saved" ]] || die 'Backup destination already exists.'
    if [[ -f "$state/original.plist" ]]; then
        check_plain_file "$state/original.plist"
        staged=$(/usr/bin/mktemp "${target}.tmp.XXXXXX")
        /bin/cp "$state/original.plist" "$staged"
        /usr/bin/plutil -lint "$staged" >/dev/null
        check_plain_file "$state/original.mode"
        check_plain_file "$state/original.gid"
        /usr/bin/chgrp "$(cat "$state/original.gid")" "$staged"
        /bin/chmod "$(cat "$state/original.mode")" "$staged"
        /bin/mv -f "$staged" "$target"
    elif [[ -f "$state/no-original" && ! -L "$state/no-original" ]]; then
        /bin/rm "$target"
    else
        die 'Incomplete receipt; no removal performed.'
    fi
    /bin/mv "$state" "$saved"
    printf 'Uninstalled. Original preferences restored; backup retained at %s\nNo service was restarted.\n' "$saved"
}

probe() {
    /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation"); ObjC.import("CoreFoundation");
var valid=Ref();
var forced=$.CFPreferencesAppValueIsForced($("forceBypassScreenCaptureAlert"),$("com.apple.applicationaccess"));
var value=$.CFPreferencesGetAppBooleanValue($("forceBypassScreenCaptureAlert"),$("com.apple.applicationaccess"),valid);
JSON.stringify({forced:Boolean(forced),value:Boolean(value),valid:Boolean(valid[0]),effective:Boolean(forced)&&Boolean(value)&&Boolean(valid[0])});'
}

secure_dir() {
    local path=$1 info owner mode
    [[ ! -L "$path" && -d "$path" ]] || die "Expected a real directory: $path"
    info=$(/usr/bin/stat -f '%u %Lp' "$path"); owner=${info%% *}; mode=${info##* }
    [[ "$owner" == 0 && $((8#$mode & 0022)) == 0 ]] || die "Directory must be root-owned and not group/world writable: $path"
}

usage() {
    cat <<'EOF'
Usage: ./screen-capture-alert.sh ACTION [--user USER] [--allow-untested]
  status     Read the effective policy (no changes; run without sudo).
  plan       Show paths and scope (no changes).
  install    Set the current-user policy; requires sudo. Keeps a backup.
  uninstall  Restore the backup only if installed preferences are unchanged.
  refresh    Send HUP to this user's replayd; interrupts screen capture.
Only macOS 27 is accepted by default. Tested: 27.0.1 (26A434), Apple silicon.
This suppresses reminders for ALL apps under the selected user. It does not
grant Screen Recording permission. No MDM enrollment, daemon or polling task.
EOF
}

main() {
    local action=${1:-help} user=${SUDO_USER:-${USER:-}} allow=no version uid target base state enrollment mode
    [[ $# == 0 ]] || shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) [[ $# -ge 2 ]] || die '--user needs a value'; user=$2; shift 2 ;;
            --allow-untested) allow=yes; shift ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    case "$action" in help|--help|-h) usage; return ;; status|plan|install|uninstall|refresh) ;; *) die "Unknown action: $action" ;; esac
    [[ $(/usr/bin/uname -s) == Darwin ]] || die 'This script is for macOS only.'
    version=$(/usr/bin/sw_vers -productVersion)
    [[ ${version%%.*} == 27 || "$allow" == yes ]] || die "macOS $version is untested; use --allow-untested only after reviewing the method."
    [[ "$user" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$user" != root ]] || die 'Select a regular local user with --user USER.'
    uid=$(/usr/bin/id -u "$user")
    [[ "$uid" -ge 501 ]] || die 'System accounts are refused.'
    target="/Library/Managed Preferences/$user/$DOMAIN.plist"
    base=/var/db/macos27-screen-capture-alert
    state="$base/$uid"
    case "$action" in
        status)
            printf 'macOS: %s | user: %s | policy: %s\n' "$version" "$user" "$target"
            if [[ $EUID == "$uid" ]]; then probe
            elif [[ $EUID == 0 ]]; then
                if [[ "$allow" == yes ]]; then /usr/bin/sudo -u "$user" /bin/bash "$0" status --user "$user" --allow-untested
                else /usr/bin/sudo -u "$user" /bin/bash "$0" status --user "$user"; fi
            else die 'Run status as the selected user.'; fi
            return ;;
        plan) printf 'Set %s=true\nTarget: %s\nBackup: %s\nScope: ALL screen-capture reminder alerts for user %s.\nNo changes made.\n' "$KEY" "$target" "$state" "$user"; return ;;
        refresh)
            [[ $EUID == "$uid" || $EUID == 0 ]] || die 'Cannot refresh another user.'
            printf 'Refreshing replayd for %s. Active screen captures may disconnect.\n' "$user"
            /usr/bin/killall -HUP -u "$user" replayd 2>/dev/null || printf 'No running replayd was signalled.\n'
            return ;;
    esac
    [[ $EUID == 0 ]] || die "Use sudo for $action. No changes made."
    enrollment=$(/usr/bin/profiles status -type enrollment 2>&1) || die 'Could not establish enrollment status.'
    if printf '%s\n' "$enrollment" | /usr/bin/grep -Eq 'MDM enrollment: Yes|Enrolled via DEP: Yes'; then die 'Managed/enrolled Mac detected; use your administrator policy instead.'; fi
    [[ "$enrollment" == *'MDM enrollment: No'* ]] || die 'Unrecognized enrollment status; no changes made.'
    if [[ "$action" == uninstall ]]; then
        [[ -d "$state" && ! -L "$state" ]] || die 'No installation receipt found; no changes made.'
    fi
    secure_dir /Library
    [[ -e '/Library/Managed Preferences' || -L '/Library/Managed Preferences' ]] || /bin/mkdir -m 755 '/Library/Managed Preferences'
    secure_dir '/Library/Managed Preferences'
    [[ -e "/Library/Managed Preferences/$user" || -L "/Library/Managed Preferences/$user" ]] || /bin/mkdir -m 755 "/Library/Managed Preferences/$user"
    secure_dir "/Library/Managed Preferences/$user"
    secure_dir /var/db
    [[ -e "$base" || -L "$base" ]] || /bin/mkdir -m 700 "$base"
    secure_dir "$base"
    [[ ! -e "$state" && ! -L "$state" ]] || secure_dir "$state"
    if [[ -e "$target" || -L "$target" ]]; then
        check_plain_file "$target"
        [[ $(/usr/bin/stat -f '%u' "$target") == 0 ]] || die 'Existing preferences must be root-owned.'
        mode=$(/usr/bin/stat -f '%Lp' "$target")
        [[ $((8#$mode & 0022)) == 0 ]] || die 'Existing preferences must not be group/world writable.'
    fi
    /bin/mkdir -m 700 "$state.lock" 2>/dev/null || die 'Another operation owns the lock; do not remove an active lock.'
    trap "/bin/rmdir '$state.lock' 2>/dev/null || true" EXIT
    case "$action" in install) install_policy "$target" "$state" ;; uninstall) uninstall_policy "$target" "$state" ;; esac
    /bin/rmdir "$state.lock"
    trap - EXIT
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
