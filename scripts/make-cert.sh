#!/bin/bash
# Один раз: создать собственный сертификат подписи и положить его в секреты GitHub.
# Нужен, чтобы у всех версий была одинаковая подпись и macOS не сбрасывала
# разрешение Accessibility после каждого обновления.
#   scripts/make-cert.sh            → печатает команды для gh secret set
set -euo pipefail
DIR="$(mktemp -d)"
PASS="$(openssl rand -hex 16)"
cat > "$DIR/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = PuntoLite Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cfg" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -name "PuntoLite Signing" -out "$DIR/cert.p12" -passout "pass:$PASS" 2>/dev/null \
|| openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -name "PuntoLite Signing" -out "$DIR/cert.p12" -passout "pass:$PASS"
base64 < "$DIR/cert.p12" | tr -d '\n' > "$DIR/cert.b64"
echo "Готово. Выполните в папке репозитория:"
echo "  gh secret set SIGNING_CERT_P12 < $DIR/cert.b64"
echo "  gh secret set SIGNING_CERT_PASSWORD --body $PASS"
echo "Сохраните $DIR/cert.p12 и пароль в надёжном месте — без них подпись сменится."
