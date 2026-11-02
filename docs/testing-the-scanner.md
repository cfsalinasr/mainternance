# Testing the scanner

Everything here is safe. The test file is harmless: it is the standard EICAR string that every antivirus
recognizes on purpose, and it cannot do anything.

## 1. Install ClamAV and get definitions
1. Open Mainternance, choose Scanner.
2. Press Install (needs Homebrew). Wait until it says ClamAV is installed.
3. Press Update definitions and wait for it to finish. Until then no scan can run.

## 2. Create the test file
Run in Terminal (the string is split in two so this document itself is not flagged):

```sh
mkdir -p ~/Desktop/eicar-test
a='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS'
b='-TEST-FILE!$H+H*'
printf '%s%s' "$a" "$b" > ~/Desktop/eicar-test/eicar.txt
```

## 3. Scan, quarantine, restore
1. In Scanner choose a custom scan of `~/Desktop/eicar-test`. It should report one detection (an `Eicar` signature).
2. Quarantine it after confirming. The file leaves the folder; the app lists it as quarantined.
3. Restore it. The file returns and is listed as a detection again.
4. Delete it yourself when done: `rm -r ~/Desktop/eicar-test`. The app never deletes files.

## Full Disk Access message
If the app says some folders could not be read, macOS blocked them. Grant Mainternance Full Disk Access in
System Settings > Privacy & Security > Full Disk Access, then scan again. Until a scan reads everything, a
detection whose file still exists stays listed.

## Weekly scan and notifications
1. In Settings turn on Problem alerts and Weekly digest. macOS asks once for permission; allow it. If it was
   refused, allow it in System Settings > Notifications > Mainternance.
2. Turn on "Run a quick scan every week" and set the day to today and the time a few minutes ahead. Keep the
   app open (the weekly scan runs only while Mainternance is open; it is checked about once a minute).
3. When the time comes a quick scan starts by itself. When it ends you get one "Weekly scan finished"
   notification with counts only (files scanned, files to review, folders that could not be read), never a file
   name. The quick scan covers the Desktop, so with the test file still there it says "1 file to review";
   without it, "nothing found" (unless something else is detected).
4. To see a problem alert, run a scan of `~/Desktop/eicar-test` by hand (as in section 3): you get
   "Mainternance found 1 file to review". A scan you start yourself never sends the weekly digest.
5. The weekly scan runs once per week. If the Mac was asleep or the app was closed at that time, it runs once
   the next time the app is open or the Mac wakes.

## Uninstall
```sh
brew uninstall clamav
rm -r "$HOME/Library/Application Support/Mainternance/ClamAV"
```
Quarantined files live in `~/Library/Application Support/Mainternance/Quarantine`; restore them from the app first.
