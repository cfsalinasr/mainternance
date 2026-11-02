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

## Uninstall
```sh
brew uninstall clamav
rm -r "$HOME/Library/Application Support/Mainternance/ClamAV"
```
Quarantined files live in `~/Library/Application Support/Mainternance/Quarantine`; restore them from the app first.
