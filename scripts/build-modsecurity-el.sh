#!/usr/bin/env bash
# Builds the ModSecurity-nginx connector for the nginx.org package on an EL system (AlmaLinux, Rocky Linux, CentOS Stream 9 or 10),
# with libmodsecurity built here and linked into the module, so the machine needs no libmodsecurity package (EPEL 10 has none).
# Then loads the module into nginx and checks that a plain rule and the OWASP Core Rule Set block attacks.
# Runs as root inside a container of that system.
#   build-modsecurity-el.sh <el9|el10> <outdir>
# Environment: NGINX_VERSION NGINX_SHA256 CONNECTOR_VERSION CONNECTOR_SHA256 MODSEC_VERSION MODSEC_SHA256
#              YAJL_VERSION YAJL_SHA256 CRS_VERSION CRS_SHA256
set -euo pipefail
el="${1:?el9 or el10}"
out="${2:?output directory}"
case "$el" in el9 | el10) ;; *) echo "el must be el9 or el10" >&2; exit 2 ;; esac
: "${NGINX_VERSION:?}" "${NGINX_SHA256:?}" "${CONNECTOR_VERSION:?}" "${CONNECTOR_SHA256:?}" "${MODSEC_VERSION:?}" "${MODSEC_SHA256:?}"
: "${YAJL_VERSION:?}" "${YAJL_SHA256:?}" "${CRS_VERSION:?}" "${CRS_SHA256:?}"
here="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -m)" in
  x86_64) suffix="" ;;
  aarch64) suffix="-arm64" ;;
  *) echo "unsupported CPU $(uname -m)" >&2; exit 2 ;;
esac

bash "$here/install-nginx-org-el.sh" "$NGINX_VERSION"

dnf -y -q install epel-release > /dev/null
dnf config-manager --set-enabled crb
# libmodsecurity is built without GeoIP, Lua, ssdeep and LMDB: the panel's rules use none of them. yajl (JSON bodies) is built
# here too, because EL10 has no yajl-devel. pcre2, libxml2 and libcurl come from the system and are linked dynamically: every EL
# machine has them.
dnf -y -q install gcc gcc-c++ make autoconf automake libtool pkgconf-pkg-config cmake file \
  pcre2-devel libxml2-devel libcurl-devel openssl-devel zlib-devel > /dev/null 2>&1 || \
  dnf -y -q install gcc gcc-c++ make autoconf automake libtool pkgconf-pkg-config cmake file \
  pcre2-devel libxml2-devel libcurl-devel openssl-devel zlib-ng-compat-devel > /dev/null

work="$(mktemp -d)"
cd "$work"
fetch() { # url sha256 file
  curl -fsSL --proto '=https' -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - > /dev/null || { echo "$3 from $1 does not match its checksum" >&2; exit 1; }
}
fetch "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "$NGINX_SHA256" nginx.tgz
fetch "https://github.com/owasp-modsecurity/ModSecurity-nginx/releases/download/v${CONNECTOR_VERSION}/modsecurity-nginx-v${CONNECTOR_VERSION}.tar.gz" "$CONNECTOR_SHA256" connector.tgz
fetch "https://github.com/owasp-modsecurity/ModSecurity/releases/download/v${MODSEC_VERSION}/modsecurity-v${MODSEC_VERSION}.tar.gz" "$MODSEC_SHA256" modsec.tgz
fetch "https://github.com/lloyd/yajl/archive/refs/tags/${YAJL_VERSION}.tar.gz" "$YAJL_SHA256" yajl.tgz
fetch "https://github.com/coreruleset/coreruleset/archive/refs/tags/v${CRS_VERSION}.tar.gz" "$CRS_SHA256" crs.tgz
mkdir nginx connector modsec yajl crs
for p in nginx connector modsec yajl crs; do tar xzf "$p.tgz" -C "$p" --strip-components=1; done

# yajl: static, position-independent, so it can sit inside a shared object.
prefix="$work/prefix"
(cd yajl && mkdir build && cd build &&
  cmake -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release .. > "$work/yajl.log" 2>&1 &&
  make -j"$(nproc)" >> "$work/yajl.log" 2>&1 && make install >> "$work/yajl.log" 2>&1) || { tail -30 "$work/yajl.log"; exit 1; }
rm -f "$prefix"/lib*/libyajl.so*
# yajl names its static library libyajl_s.a; -lyajl looks for libyajl.a.
for d in "$prefix"/lib*; do [ -f "$d/libyajl_s.a" ] && ln -sf libyajl_s.a "$d/libyajl.a"; done

# libmodsecurity: static only, with -fPIC.
(cd modsec &&
  ./configure --prefix="$prefix" --enable-static --disable-shared --with-pic --with-pcre2 --with-yajl="$prefix" \
    --without-geoip --without-maxmind --without-lua --without-ssdeep --without-lmdb --disable-doxygen-doc --disable-examples \
    > "$work/modsec-configure.log" 2>&1 || { tail -40 "$work/modsec-configure.log"; exit 1; }
  # Only the library and its headers; the command line tools are not needed.
  # The library needs the bundled code under others/ (libinjection, mbedtls), which the top Makefile builds first.
  make -C others -j"$(nproc)" > "$work/modsec-make.log" 2>&1 || { tail -40 "$work/modsec-make.log"; exit 1; }
  make -C src -j"$(nproc)" >> "$work/modsec-make.log" 2>&1 || { tail -40 "$work/modsec-make.log"; exit 1; }
  # headers/ has no Makefile of its own; src installs the library, and the headers are copied by hand.
  make -C src install > /dev/null
  mkdir -p "$prefix/include" && cp -r headers/modsecurity "$prefix/include/")
libdir="$(dirname "$(find "$prefix" -name libmodsecurity.a | head -1)")"
yajl_a="$(find "$prefix" -name 'libyajl_s.a' | head -1)"
[ -f "$libdir/libmodsecurity.a" ] && [ -f "$yajl_a" ] || { echo "the static libraries were not built" >&2; exit 1; }

# The connector links -lmodsecurity; with only the .a in that folder, the linker takes the static one. Its own dependencies are
# added after it, in the order the linker needs them.
deps="$yajl_a -lpcre2-8 -lxml2 -lcurl -lstdc++ -lm"
args="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p' | sed -E "s/--with-cc-opt='[^']*'//; s/--with-ld-opt='[^']*'//")"
cd nginx
MODSECURITY_INC="$prefix/include" MODSECURITY_LIB="$libdir" NGX_IGNORE_RPATH=YES \
  eval ./configure "$args" --with-ld-opt="'$deps'" --add-dynamic-module="$work/connector" > "$work/configure.log" 2>&1 ||
  { tail -40 "$work/configure.log"; exit 1; }
make -j"$(nproc)" modules > "$work/make.log" 2>&1 || { tail -40 "$work/make.log"; exit 1; }

mkdir -p "$out"
so="$out/ngx_http_modsecurity_module-${el}-nginx${NGINX_VERSION}${suffix}.so"
cp objs/ngx_http_modsecurity_module.so "$so"
strip --strip-unneeded "$so"
if ldd "$so" | grep -qE 'libmodsecurity|libyajl'; then echo "FAIL  the module still needs a shared libmodsecurity or libyajl" >&2; ldd "$so" >&2; exit 1; fi
{
  echo "distro: ${el} ($(. /etc/os-release; echo "$PRETTY_NAME"))"
  echo "cpu: $(uname -m)"
  echo "nginx: ${NGINX_VERSION} (nginx.org package)"
  echo "connector: ${CONNECTOR_VERSION}"
  echo "libmodsecurity: ${MODSEC_VERSION} (static, inside the module)"
  echo "yajl: ${YAJL_VERSION} (static, inside the module)"
  echo "glibc: $(ldd --version | head -1)"
  echo "links:"
  ldd "$so" | sed 's/^/  /'
} | tee "$out/info-${el}${suffix}.txt"

# The OWASP Core Rule Set is published next to the module, as the panel installs it on EL (there is no package).
crsout="$out/coreruleset-${CRS_VERSION}.tar.gz"
[ -f "$crsout" ] || cp "$work/crs.tgz" "$crsout"

# --- test: the module has to load and has to block ---------------------------------------------------------------------------
t="$(mktemp -d)"
chmod 755 "$t"
mkdir -p "$t/www"
echo hello > "$t/www/index.html"
cp "$work/modsec/modsecurity.conf-recommended" "$t/modsecurity.conf"
cp "$work/modsec/unicode.mapping" "$t/unicode.mapping"
sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' "$t/modsecurity.conf"
cp "$work/crs/crs-setup.conf.example" "$t/crs-setup.conf"
cat > "$t/simple.conf" << EOF
Include $t/modsecurity.conf
SecRule ARGS "@contains attack" "id:1001,phase:2,deny,status:403,log"
EOF
cat > "$t/crs.conf" << EOF
Include $t/modsecurity.conf
Include $t/crs-setup.conf
Include $work/crs/rules/*.conf
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
expect() { if [ "$2" = "$3" ]; then echo "ok    $1 -> $3"; else echo "FAIL  $1 -> $3 (wanted $2)"; fail=1; fi; }
# The workers of the nginx.org package run as "nginx" and must read the rules.
chmod -R a+rX "$work/crs" "$t"
chmod 755 "$work"

conf "$t/simple.conf" simple
nginx -t -c "$t/nginx-simple.conf" -p "$t/"
nginx -c "$t/nginx-simple.conf" -p "$t/"
sleep 1
expect "plain rule, normal request" 200 "$(code 'http://127.0.0.1:18081/?x=hello')"
expect "plain rule, attack" 403 "$(code 'http://127.0.0.1:18081/?x=attack')"
expect "JSON body is parsed (yajl)" 403 "$(code -H 'Content-Type: application/json' --data '{"x":"attack"}' 'http://127.0.0.1:18081/')"
nginx -s stop -c "$t/nginx-simple.conf" -p "$t/"
sleep 1

conf "$t/crs.conf" crs
nginx -t -c "$t/nginx-crs.conf" -p "$t/"
nginx -c "$t/nginx-crs.conf" -p "$t/"
sleep 2
expect "OWASP CRS, normal request" 200 "$(code 'http://127.0.0.1:18081/index.html?page=2')"
expect "OWASP CRS, SQL injection" 403 "$(code "http://127.0.0.1:18081/?id=1%27%20OR%20%271%27%3D%271")"
expect "OWASP CRS, XSS" 403 "$(code 'http://127.0.0.1:18081/?q=%3Cscript%3Ealert(1)%3C/script%3E')"
expect "OWASP CRS, scanner" 403 "$(code -A 'sqlmap/1.7' 'http://127.0.0.1:18081/')"
nginx -s stop -c "$t/nginx-crs.conf" -p "$t/"
if [ "$fail" != 0 ]; then
  echo "--- nginx error logs ---"
  for f in "$t"/*.log; do echo "# $f"; tail -n 12 "$f"; done
fi
exit "$fail"
