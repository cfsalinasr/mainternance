#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Mainternance Local Signing" in the login keychain,
# so rebuilt apps keep a stable signature (and macOS keeps granted permissions such as Full Disk Access).
# Idempotent. Use --dry-run to print the commands without running them.
set -euo pipefail

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
    echo "Signing identity '$NAME' already exists in the keychain. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mainternance-cert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
P12_PASS="mainternance-$$"

run() {
    echo "+ $*"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$@"
    fi
}

echo "Creating signing identity '$NAME' (valid $DAYS days)."
[[ "$DRY_RUN" -eq 1 ]] && echo "Dry run: nothing below is executed."

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
    echo "Dry run complete. Temporary files would be removed on exit."
else
    echo "Done. Verify with: security find-identity -v -p codesigning"
fi
