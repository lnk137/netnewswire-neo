#!/bin/bash
set -euo pipefail
# A persistent, app-specific certificate keeps Keychain access stable across builds.
identity_name='NetNewsWire Neo Local Development'
find_identity() {
  security find-identity -p codesigning | awk -v name="\"$identity_name\"" 'index($0, name) { print $2; exit }'
}
identity=$(find_identity)
if [ -z "$identity" ]; then
  umask 077
  signing_dir=$(mktemp -d "${TMPDIR:-/tmp}/netnewswire-signing.XXXXXX")
  trap 'rm -rf "$signing_dir"' EXIT
  cat > "$signing_dir/openssl.cnf" <<'CONF'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = NetNewsWire Neo Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF
  /usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -config "$signing_dir/openssl.cnf" -keyout "$signing_dir/key.pem" -out "$signing_dir/cert.pem" 2>/dev/null
  signing_password=$(/usr/bin/openssl rand -hex 24)
  printf "%s" "$signing_password" > "$signing_dir/password"
  /usr/bin/openssl pkcs12 -export -inkey "$signing_dir/key.pem" -in "$signing_dir/cert.pem" \
    -name "$identity_name" -out "$signing_dir/identity.p12" -passout "file:$signing_dir/password"
  keychain=$(security default-keychain -d user | tr -d '"' | sed 's/^ *//')
  security import "$signing_dir/identity.p12" -k "$keychain" -P "$signing_password" -T /usr/bin/codesign >&2
  identity=$(find_identity)
fi
if [ -z "$identity" ]; then
  echo 'Unable to locate the local signing identity.' >&2
  exit 1
fi
printf '%s\n' "$identity"
