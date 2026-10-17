#!/usr/env/bin bash
set -euo pipefail

# Inputs from ARM
superuserUsername="$1"
superuserEmail="$2"
superuserPassword="$3"
allowedHosts="$4"
cognosAllowedHosts="$5"
vmSize="$6"

# Certificate Inputs from ARM (Base64-encoded strings from FileUpload)
tlsCertB64="${7:-}"
tlsKeyB64="${8:-}"
cognosCertB64="${9:-}"
encodedInitialLicense="${10:-}"

BASE_DIR="/opt/simpliload"
DEPLOY_DIR="$BASE_DIR/deploy"
CERT_DIR="$DEPLOY_DIR/certs"
ENV_TEMPLATE="$DEPLOY_DIR/.env.template"
ENV_FILE="$BASE_DIR/.env"

mkdir -p "$BASE_DIR"
mkdir -p "$CERT_DIR"

echo "== Downloading and extracting release bundle =="
BUNDLE_URL="https://hofstetr.github.io/products/simpliload/downloads/simpliload.zip"
curl -sL "$BUNDLE_URL" -o "$BASE_DIR/simpliload.zip"
python3 -c "import zipfile; zipfile.ZipFile('$BASE_DIR/simpliload.zip', 'r').extractall('$BASE_DIR')"
rm "$BASE_DIR/simpliload.zip"

echo "== Generating secrets =="

djangoSecretKey="$(openssl rand -hex 32)"
masterKey="$(openssl rand -hex 32)"
postgresPassword="$(openssl rand -hex 16)"

echo "== Computing ASGI_THREADS from VM size =="

case "$vmSize" in
  "Standard_D2s_v4")
    asgiThreads="20"
    ;;
  "Standard_D4s_v4")
    asgiThreads="40"
    ;;
  "Standard_D8s_v4")
    asgiThreads="80"
    ;;
  *)
    asgiThreads="20"
    ;;
esac

echo "== Handling TLS certificate =="

# Helper function to check if base64 input contains valid content
is_valid_b64() {
  local val="$1"
  [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" != "\"\"" ] && [ "$val" != "e30=" ]
}

if is_valid_b64 "$tlsCertB64" && is_valid_b64 "$tlsKeyB64"; then
  echo "Decoding provided TLS Certificate and Key..."
  echo "$tlsCertB64" | base64 -d > "$CERT_DIR/server.crt"
  echo "$tlsKeyB64" | base64 -d > "$CERT_DIR/server.key"
  chmod 600 "$CERT_DIR/server.key"
else
  echo "No TLS certificate provided. Generating self-signed fallback certificate..."

  # Build SAN list properly
  sanList=$(echo "$allowedHosts" | tr ',' '\n' | sed 's/^/DNS:/')
  sanJoined=$(paste -sd, <<< "$sanList")

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -days 365 \
    -subj "/CN=$(echo "$allowedHosts" | cut -d',' -f1)" \
    -addext "subjectAltName=${sanJoined}"

  chmod 600 "$CERT_DIR/server.key"
fi

sslCertHostPath="./deploy/certs/server.crt"
sslKeyHostPath="./deploy/certs/server.key"

echo "== Handling Cognos CA cert (optional) =="

cognosCertHostPath=""
if is_valid_b64 "$cognosCertB64"; then
  echo "Decoding provided Cognos CA certificate..."
  echo "$cognosCertB64" | base64 -d > "$CERT_DIR/cognos.pem"
  chmod 644 "$CERT_DIR/cognos.pem"
  cognosCertHostPath="./deploy/certs/cognos.pem"
fi

echo "== Building CSRF_TRUSTED_ORIGINS from ALLOWED_HOSTS =="

csrfTrustedOrigins=$(printf '%s' "$allowedHosts" | sed 's|,|,https://|g; s|^|https://|')

echo "== Building .env from template =="

cp "$ENV_TEMPLATE" "$ENV_FILE"

sed -i "s|\${djangoSecretKey}|$djangoSecretKey|g" "$ENV_FILE"
sed -i "s|\${masterKey}|$masterKey|g" "$ENV_FILE"
sed -i "s|\${superuserUsername}|$superuserUsername|g" "$ENV_FILE"
sed -i "s|\${superuserEmail}|$superuserEmail|g" "$ENV_FILE"
sed -i "s|\${superuserPassword}|$superuserPassword|g" "$ENV_FILE"
sed -i "s|\${postgresPassword}|$postgresPassword|g" "$ENV_FILE"
sed -i "s|\${allowedHosts}|$allowedHosts|g" "$ENV_FILE"
sed -i "s|\${csrfTrustedOrigins}|$csrfTrustedOrigins|g" "$ENV_FILE"
sed -i "s|\${asgiThreads}|$asgiThreads|g" "$ENV_FILE"
sed -i "s|\${cognosAllowedHosts}|$cognosAllowedHosts|g" "$ENV_FILE"
sed -i "s|\${cognosCertHostPath}|$cognosCertHostPath|g" "$ENV_FILE"
sed -i "s|\${sslCertHostPath}|$sslCertHostPath|g" "$ENV_FILE"
sed -i "s|\${sslKeyHostPath}|$sslKeyHostPath|g" "$ENV_FILE"

echo "== Writing initial license file =="
echo "$encodedInitialLicense" > "$DEPLOY_DIR/license.dat"
chmod 600 "$DEPLOY_DIR/license.dat"

echo "== Writing edition metadata =="

echo "single" > "$DEPLOY_DIR/edition"

echo "== Installing Docker (if needed) =="

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

cd "$BASE_DIR"

echo "Pulling application images..."
docker compose pull

echo "== Starting SimpliLoad (single) =="
docker compose up -d

echo "== Deployment complete =="

cat <<EOF

SimpliLoad (SINGLE) admin credentials:
  URL:       https://${allowedHosts}
  Username: ${superuserUsername}
  Email:    ${superuserEmail}
  Password: ${superuserPassword}
  VM Size:  ${vmSize}
  ASGI_THREADS: ${asgiThreads}

EOF