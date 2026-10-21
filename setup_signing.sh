#!/bin/bash
# Crée une fois une identité de signature auto-signée persistante dans un trousseau
# dédié (mot de passe connu → aucun prompt). Grâce à elle, build.sh signe avec une
# exigence basée sur le certificat, et l'autorisation Accessibilité survit aux
# recompilations. La confiance du cert n'importe pas : "not trusted" bloque la
# vérification, pas la signature ; macOS accepte une app self-signed pour l'Accès.
set -euo pipefail

SIGN_CN="Flick Dev"
KC="$HOME/Library/Keychains/flick-signing.keychain-db"
KCPASS="flickpass"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Flick Dev
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf"
openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
  -out "$TMP/id.p12" -passout pass:flick -name "$SIGN_CN"

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P flick -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
EXIST=$(security list-keychains -d user | sed 's/[" ]//g')
security list-keychains -d user -s "$KC" $EXIST

echo "✓ Identité « $SIGN_CN » prête (CSSMERR_TP_NOT_TRUSTED est normal) :"
security find-identity "$KC" | grep "$SIGN_CN" || { echo "ÉCHEC"; exit 1; }
