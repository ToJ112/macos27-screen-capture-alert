# macOS 27 Screen Capture Alert Suppression

[中文](README.md)

A local, per-user forced preference to suppress the recurring screen-capture acknowledgement dialog. **Tested only on macOS 27.0.1, build 26A434, Apple silicon, without MDM enrollment.** Other macOS 27 versions, Intel Macs, a full reboot and OS upgrades have not been verified.

This affects **all applications for the selected user**. It does not grant Screen Recording permission, hide recording indicators, enroll the Mac in MDM, disable SIP, modify TCC or patch system binaries. No background service or polling task is installed. It uses built-in macOS tools; Python, Homebrew and REA are not runtime dependencies.

This is an experimentally verified local managed-preference method, not an Apple-supported personal-Mac setting. Managed/enrolled Macs are refused. Future OS changes or preference reconciliation may change its effect.

## Usage

Download/extract the repository, review the script and open Terminal in that directory:

```bash
bash ./screen-capture-alert.sh plan
bash ./screen-capture-alert.sh status
sudo bash ./screen-capture-alert.sh install
bash ./screen-capture-alert.sh status
```

The default target is the original user running `sudo`. To select a regular local account explicitly, add `--user YOUR_SHORT_USERNAME`.

The script sets `forceBypassScreenCaptureAlert=true` in:

```text
/Library/Managed Preferences/<username>/com.apple.applicationaccess.plist
```

It backs up an existing file, preserves unrelated preferences, file mode and group, and keeps receipts under `/var/db/macos27-screen-capture-alert/<uid>/`. If the value is already true without this script's receipt, it reports that fact without claiming ownership.

Run `status` as the target user, without `sudo`. CoreFoundation must report **forced=true, value=true, valid=true, effective=true**; a true value in a file alone is insufficient.

After stopping recording, screen sharing and screenshot-dependent automation, optionally refresh the system service:

```bash
bash ./screen-capture-alert.sh refresh
```

This sends HUP to the user's `replayd` and can interrupt active capture sessions. Install/uninstall never restart services automatically. Test with your actual capture application afterward.

## Undo

```bash
sudo bash ./screen-capture-alert.sh uninstall
# Only at a safe capture boundary:
bash ./screen-capture-alert.sh refresh
bash ./screen-capture-alert.sh status
```

Uninstall restores the original file (or removes the newly created one) **only if the installed file's digest is unchanged**. If another tool edited it, uninstall refuses to overwrite it; compare the retained backup and merge manually. Removed-installation receipts are retained in a timestamped directory. A policy installed externally is not removed without a receipt.

Do not blindly delete a lock/receipt after interruption. Confirm no installer is running, then inspect the target and backup.

## Verification and mechanism

The observed failure involved a short-lived `screencapture` process exiting before `replayd` finished identity checks. Its unresolved-identity branch requests an alert without consulting reminder dates.

REA + Rizin inspection found that this build's bypass method checks a forced, valid true preference, rather than directly querying enrollment in that method. The local preference satisfied the same condition. Three real captures succeeded after refreshing `replayd`; the test log contained six policy-bypass entries and no alert constructor calls. This does not establish that every repeated alert has the same cause.

See [sanitized verification details](docs/verification.md). `--allow-untested` only overrides the major-version gate; it does not establish compatibility or override ownership/conflict checks.

## Development

```bash
python3 -m unittest discover -s tests -v
bash -n screen-capture-alert.sh
```

Tests use temporary files only, not real policy paths or service restarts. Python 3 is needed for tests only. MIT License.
