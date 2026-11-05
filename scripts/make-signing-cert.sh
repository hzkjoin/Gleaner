#!/usr/bin/env bash
# Creates the "Gleaner Self-Signed" code signing certificate in the login keychain, and a backup
# (.p12 and its password) in ~/.gleaner-signing. Keep that backup: releases must always be signed
# with the same certificate, or installed copies lose their permissions and reject updates.
#
# To use an existing backup on another Mac instead:
#   security import ~/.gleaner-signing/gleaner-signing.p12 -k ~/Library/Keychains/login.keychain-db \
#       -P "$(cat ~/.gleaner-signing/p12-password.txt)" -T /usr/bin/codesign
set -euo pipefail

NAME="Gleaner Self-Signed"
DIR="$HOME/.gleaner-signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists"
    exit 0
fi
mkdir -p "$DIR" && chmod 700 "$DIR"
cd "$DIR"
cat > cert.cnf <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Gleaner Self-Signed
O = Gleaner
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
echo "$PASS" > p12-password.txt
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out gleaner-signing.p12 -passout pass:"$PASS"
rm -f key.pem
chmod 600 p12-password.txt gleaner-signing.p12
security import gleaner-signing.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\"; back up $DIR"
