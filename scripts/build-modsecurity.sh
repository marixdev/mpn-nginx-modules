#!/usr/bin/env bash
# Builds the ModSecurity-nginx connector against the source of one nginx version, loads it into the nginx.org package of that
# version and checks that it blocks. Runs as root inside a Debian or Ubuntu container.
#   build-modsecurity.sh <codename> <debian|ubuntu> <outdir>
# Environment: NGINX_VERSION NGINX_SHA256 CONNECTOR_VERSION CONNECTOR_SHA256
set -euo pipefail
codename="${1:?codename}"
family="${2:?family}"
out="${3:?output directory}"
: "${NGINX_VERSION:?}" "${NGINX_SHA256:?}" "${CONNECTOR_VERSION:?}" "${CONNECTOR_SHA256:?}"
here="$(cd "$(dirname "$0")" && pwd)"

bash "$here/install-nginx-org.sh" "$codename" "$family" "$NGINX_VERSION"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends build-essential libpcre2-dev zlib1g-dev libssl-dev \
  libmodsecurity-dev modsecurity-crs

work="$(mktemp -d)"
cd "$work"
curl -fsSL --proto '=https' -o nginx.tgz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
echo "${NGINX_SHA256}  nginx.tgz" | sha256sum -c -
curl -fsSL --proto '=https' -o connector.tgz \
  "https://github.com/owasp-modsecurity/ModSecurity-nginx/releases/download/v${CONNECTOR_VERSION}/modsecurity-nginx-v${CONNECTOR_VERSION}.tar.gz"
echo "${CONNECTOR_SHA256}  connector.tgz" | sha256sum -c -
mkdir nginx connector
tar xzf nginx.tgz -C nginx --strip-components=1
tar xzf connector.tgz -C connector --strip-components=1

# The same arguments as the installed package: a dynamic module is built for one exact nginx and one exact configuration.
args="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p' | sed -E "s/--with-cc-opt='[^']*'//; s/--with-ld-opt='[^']*'//")"
cd nginx
eval ./configure "$args" --add-dynamic-module="$work/connector" > "$work/configure.log" 2>&1 || { tail -30 "$work/configure.log"; exit 1; }
make -j"$(nproc)" modules > "$work/make.log" 2>&1 || { tail -40 "$work/make.log"; exit 1; }

mkdir -p "$out"
so="$out/ngx_http_modsecurity_module-${codename}-nginx${NGINX_VERSION}.so"
cp objs/ngx_http_modsecurity_module.so "$so"
{
  echo "distro: ${family} ${codename}"
  echo "nginx: ${NGINX_VERSION} (nginx.org package)"
  echo "connector: ${CONNECTOR_VERSION}"
  echo "libmodsecurity: $(dpkg-query -W -f='${Package} ${Version}' 'libmodsecurity3*' 2> /dev/null | head -1)"
  echo "glibc: $(ldd --version | head -1)"
  echo "links:"
  ldd "$so" | sed 's/^/  /'
} | tee "$out/info-${codename}.txt"

# --- test: the module has to load and has to block ---------------------------------------------------------------------------
t="$(mktemp -d)"
mkdir -p "$t/www"
echo hello > "$t/www/index.html"
cat > "$t/simple.conf" << 'EOF'
SecRuleEngine On
SecRule ARGS "@contains attack" "id:1001,phase:2,deny,status:403,log"
EOF
cat > "$t/crs.conf" << 'EOF'
SecRuleEngine On
SecRequestBodyAccess On
Include /etc/modsecurity/crs/crs-setup.conf
Include /usr/share/modsecurity-crs/rules/*.conf
EOF
conf() {
  cat > "$t/nginx-$2.conf" << EOF
load_module $so;
pid $t/$2.pid;
error_log $t/$2.log info;
events { worker_connections 64; }
http {
  access_log off;
  server {
    listen 127.0.0.1:18081;
    modsecurity on;
    modsecurity_rules_file $1;
    root $t/www;
    location / { try_files \$uri /index.html; }
  }
}
EOF
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
fail=0
expect() { # description wanted got
  if [ "$2" = "$3" ]; then echo "ok    $1 -> $3"; else echo "FAIL  $1 -> $3 (wanted $2)"; fail=1; fi
}

conf "$t/simple.conf" simple
nginx -t -c "$t/nginx-simple.conf" -p "$t/"
nginx -c "$t/nginx-simple.conf" -p "$t/"
sleep 1
expect "plain rule, normal request" 200 "$(code 'http://127.0.0.1:18081/?x=hello')"
expect "plain rule, attack" 403 "$(code 'http://127.0.0.1:18081/?x=attack')"
nginx -s stop -c "$t/nginx-simple.conf" -p "$t/"
sleep 1

if [ -f /etc/modsecurity/crs/crs-setup.conf ] && ls /usr/share/modsecurity-crs/rules/*.conf > /dev/null 2>&1; then
  conf "$t/crs.conf" crs
  nginx -t -c "$t/nginx-crs.conf" -p "$t/"
  nginx -c "$t/nginx-crs.conf" -p "$t/"
  sleep 2
  expect "OWASP CRS, normal request" 200 "$(code 'http://127.0.0.1:18081/index.html?page=2')"
  expect "OWASP CRS, SQL injection" 403 "$(code "http://127.0.0.1:18081/?id=1%27%20OR%20%271%27%3D%271")"
  expect "OWASP CRS, XSS" 403 "$(code 'http://127.0.0.1:18081/?q=%3Cscript%3Ealert(1)%3C/script%3E')"
  expect "OWASP CRS, scanner" 403 "$(code -A 'sqlmap/1.7' 'http://127.0.0.1:18081/')"
  nginx -s stop -c "$t/nginx-crs.conf" -p "$t/"
else
  echo "NOTE  the OWASP rule set is not where this script looks on ${codename}; only the plain rule was checked"
fi
exit "$fail"
