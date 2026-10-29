#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Mainternance Local Signing" in the login keychain,
# so rebuilt apps keep a stable signature (and macOS keeps granted permissions such as Full Disk Access).
# Idempotent: handles a valid identity, a half-finished earlier run (certificate not trusted) and a fresh start.
# Use --dry-run to print the detected case and the commands it would run (read-only probes only).
set -euo pipefail
umask 077

NAME="Mainternance Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=1825
DRY_RUN=0

case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "Case (a): valid signing identity '$NAME' already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mainternance-cert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
P12_PASS="$(openssl rand -hex 16)"

# Prints the command (secrets masked) and runs it unless --dry-run.
run() {
    local shown="${*//$P12_PASS/****}"
    echo "+ $shown"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$@"
    fi
}

[[ "$DRY_RUN" -eq 1 ]] && echo "Dry run: commands are printed, not executed."

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Case (b): a certificate '$NAME' is in the keychain but is not a valid identity"
    echo "(trust step missing or cancelled, or the certificate expired). Not importing again."
    echo "Re-running only the trust step for the existing certificate."
    echo "+ security find-certificate -c '$NAME' -p '$KEYCHAIN' > cert.pem"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem"
    fi
    run security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "Trust step done. If it is still not valid the certificate may be expired: delete it in"
        echo "Keychain Access and run this script again. Check: security find-identity -v -p codesigning"
    fi
    exit 0
fi

echo "Case (c): nothing found. Creating signing identity '$NAME' (valid $DAYS days)."

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

run openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem"
# OpenSSL 3 needs -legacy so macOS `security` can read the PKCS#12; LibreSSL has no such flag.
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    LEGACY=(-legacy)
fi
run openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASS"
run security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS asks for your password)."
run security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run complete. Temporary files are removed on exit."
else
    echo "Done. Verify with: security find-identity -v -p codesigning"
fi
