#!/usr/bin/env bash
# Builds one old PHP (7.0 to 7.3, which Remi no longer has for EL 9 and 10) for an EL system, as a tarball that unpacks into
# /opt/mpn/php/<major.minor>. The extensions are the ones Mini Panel installs on Debian and Ubuntu: fpm, cli, mysqli and pdo_mysql,
# mbstring, xml, curl, zip, gd (with jpeg, png, webp, freetype) and opcache. OpenSSL 3 is too new for PHP 7.0 to 7.3, so OpenSSL
# 1.1.1 is built here and linked in statically. Then the build is checked: php -v, every extension loads, php-fpm answers a page.
# Runs as root inside a container of that system.
#   build-php-el.sh <el9|el10> <php version> <php sha256> <outdir>
# Environment: OPENSSL_VERSION OPENSSL_SHA256
set -euo pipefail
el="${1:?el9 or el10}"
ver="${2:?php version, such as 7.3.33}"
sha="${3:?sha256 of php-<version>.tar.xz}"
out="${4:?output directory}"
case "$el" in el9 | el10) ;; *) echo "el must be el9 or el10" >&2; exit 2 ;; esac
[[ "$ver" =~ ^7\.[0-3]\.[0-9]+$ ]] || { echo "only PHP 7.0 to 7.3 are built here" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "bad sha256" >&2; exit 2; }
: "${OPENSSL_VERSION:?}" "${OPENSSL_SHA256:?}"
mm="${ver%.*}"
case "$(uname -m)" in
  x86_64) suffix="" ;;
  aarch64) suffix="-arm64" ;;
  *) echo "unsupported CPU $(uname -m)" >&2; exit 2 ;;
esac
prefix="/opt/mpn/php/$mm"

dnf -y -q install epel-release > /dev/null
dnf config-manager --set-enabled crb
dnf -y -q install gcc gcc-c++ make autoconf bison re2c pkgconf-pkg-config file xz perl tar \
  libxml2-devel libcurl-devel sqlite-devel oniguruma-devel libzip-devel bzip2-devel \
  libpng-devel libjpeg-turbo-devel libwebp-devel freetype-devel libicu-devel > /dev/null
dnf -y -q install zlib-devel > /dev/null 2>&1 || dnf -y -q install zlib-ng-compat-devel > /dev/null

work="$(mktemp -d)"
cd "$work"
curl -fsSL --proto '=https' -o php.txz "https://www.php.net/distributions/php-${ver}.tar.xz"
echo "${sha}  php.txz" | sha256sum -c - > /dev/null || { echo "php-${ver}.tar.xz does not match its checksum" >&2; exit 1; }
curl -fsSL --proto '=https' -o openssl.tgz "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-${OPENSSL_VERSION}.tar.gz"
echo "${OPENSSL_SHA256}  openssl.tgz" | sha256sum -c - > /dev/null || { echo "openssl-${OPENSSL_VERSION} does not match its checksum" >&2; exit 1; }
mkdir php openssl
tar xJf php.txz -C php --strip-components=1
tar xzf openssl.tgz -C openssl --strip-components=1

# OpenSSL 1.1.1, static, inside the PHP folder so nothing else on the machine sees it. It reads the system's CA bundle.
ossl="$work/ossl"
(cd openssl && ./config --prefix="$ossl" --openssldir=/etc/pki/tls no-shared no-tests -fPIC > "$work/openssl.log" 2>&1 &&
  make -j"$(nproc)" >> "$work/openssl.log" 2>&1 && make install_sw >> "$work/openssl.log" 2>&1) || { tail -30 "$work/openssl.log"; exit 1; }

# intl is built only on EL9: ext/intl of PHP 7.0 to 7.3 does not compile against ICU 74 (EL10), which changed the return type
# of BreakIterator::operator== and removed TRUE and FALSE. Mini Panel does not install intl on Debian and Ubuntu either, so a site
# loses nothing it had there.
intl=()
[ "$el" = el9 ] && intl=(--enable-intl)
# PHP before 7.4 finds the image libraries by folder, and gd's options differ between 7.3 and older.
gd=(--with-gd --with-jpeg-dir=/usr --with-png-dir=/usr --with-webp-dir=/usr --with-freetype-dir=/usr)
# GCC 11 and newer reject some old code by default (GCC 14 on EL10 turns pointer type mismatches into errors, and libxml2 2.12
# made some pointers const); these keep the 2019 sources compiling as they did then. ICU 61 and newer no longer put their names
# in the global namespace, which ext/intl of PHP 7.0 and 7.1 expect.
export CFLAGS="-O2 -fPIC -fcommon -std=gnu99 -Wno-error -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int"
export CXXFLAGS="-O2 -fPIC -std=gnu++11 -DU_USING_ICU_NAMESPACE=1"
# The OpenSSL 1.1.1 linked into php must stay private: the system libcurl loads OpenSSL 3, and exported 1.1.1 names would take the
# place of its functions (https through curl then fails).
export LDFLAGS="-Wl,--exclude-libs,ALL"
export PKG_CONFIG_PATH="$ossl/lib64/pkgconfig:$ossl/lib/pkgconfig"
cd php
./configure --prefix="$prefix" --with-config-file-path="$prefix/etc" --with-config-file-scan-dir="$prefix/etc/conf.d" \
  --enable-fpm --with-fpm-user=nobody --with-fpm-group=nobody --with-fpm-systemd=no \
  --disable-cgi --disable-phpdbg --without-pear \
  --with-openssl="$ossl" --with-zlib --with-curl --with-libxml-dir=/usr \
  --enable-mbstring --enable-xml --enable-dom --enable-simplexml --enable-xmlreader --enable-xmlwriter \
  --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --enable-mysqlnd --with-pdo-sqlite --with-sqlite3 \
  --enable-zip --with-libzip --with-bz2 --enable-bcmath "${intl[@]}" --enable-exif --enable-ftp --enable-sockets \
  --enable-opcache "${gd[@]}" > "$work/configure.log" 2>&1 || { tail -40 "$work/configure.log"; exit 1; }
make -j"$(nproc)" > "$work/make.log" 2>&1 || { grep -m5 -B2 -A5 ' error' "$work/make.log" || tail -40 "$work/make.log"; exit 1; }
make install > "$work/install.log" 2>&1 || { tail -20 "$work/install.log"; exit 1; }
cd /

# Keep only what runs; the headers, man pages and build tools are not needed on a server.
rm -rf "$prefix/include" "$prefix/php/man" "$prefix/man" "$prefix/lib/php/build" "$prefix/bin/phpize" "$prefix/bin/php-config"
mkdir -p "$prefix/etc/conf.d" "$prefix/etc/php-fpm.d"
cp "$work/php/php.ini-production" "$prefix/etc/php.ini"
# The CA bundle of EL, for PHP's own OpenSSL (its built-in default path is the temporary build folder).
printf 'openssl.cafile=/etc/pki/tls/certs/ca-bundle.crt\ncurl.cainfo=/etc/pki/tls/certs/ca-bundle.crt\n' > "$prefix/etc/conf.d/00-ca.ini"
echo "zend_extension=opcache.so" > "$prefix/etc/conf.d/10-opcache.ini"
cat > "$prefix/etc/php-fpm.conf" << EOF
[global]
pid = /run/php-fpm-$mm.pid
error_log = syslog
syslog.ident = php-fpm$mm
include = $prefix/etc/php-fpm.d/*.conf
EOF
strip --strip-unneeded "$prefix/bin/php" "$prefix/sbin/php-fpm" "$prefix"/lib/php/extensions/*/*.so 2> /dev/null || true

# --- check ----------------------------------------------------------------------------------------------------------------------
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 -> $3 (wanted $2)"; fail=1; fi; }
"$prefix/bin/php" -v
expect "php -v says $ver" "$ver" "$("$prefix/bin/php" -r 'echo PHP_VERSION;')"
exts=(curl gd mbstring mysqli pdo_mysql openssl xml dom simplexml zip zlib bcmath exif "Zend OPcache")
[ "${#intl[@]}" = 0 ] || exts+=(intl)
for e in "${exts[@]}"; do
  expect "extension $e loads" yes "$("$prefix/bin/php" -r "echo extension_loaded('$e') ? 'yes' : 'no';")"
done
expect "gd has jpeg, png, webp, freetype" 1111 "$("$prefix/bin/php" -r '$i=gd_info(); echo (int)$i["JPEG Support"],(int)$i["PNG Support"],(int)$i["WebP Support"],(int)$i["FreeType Support"];')"
# PHP's own TLS (streams, openssl_*) uses the OpenSSL 1.1.1 built above; the curl extension uses the system libcurl, which brings
# the system's OpenSSL 3 with it. Both must reach an HTTPS site with the system CA bundle.
ldd "$prefix/bin/php" | grep -E 'libssl|libcrypto|libcurl' || true
expect "PHP's OpenSSL is 1.1.1" yes "$("$prefix/bin/php" -r 'echo strpos(OPENSSL_VERSION_TEXT, "OpenSSL 1.1.1") === 0 ? "yes" : OPENSSL_VERSION_TEXT;')"
expect "https through PHP streams" yes "$("$prefix/bin/php" -d openssl.cafile=/etc/pki/tls/certs/ca-bundle.crt -r 'echo @file_get_contents("https://www.php.net/", false, null, 0, 10) !== false ? "yes" : "no";')"
expect "https through curl" 200 "$("$prefix/bin/php" -r '$c=curl_init("https://www.php.net/"); curl_setopt($c, CURLOPT_RETURNTRANSFER, 1); curl_setopt($c, CURLOPT_NOBODY, 1); curl_setopt($c, CURLOPT_TIMEOUT, 20); curl_exec($c); echo curl_getinfo($c, CURLINFO_HTTP_CODE) ?: curl_error($c);')"

# php-fpm answers a request through its socket (cgi-fcgi is not installed, so a tiny FastCGI client in PHP itself is used).
mkdir -p /srv/t && echo '<?php echo "fpm ", PHP_VERSION;' > /srv/t/i.php
cat > "$prefix/etc/php-fpm.d/t.conf" << EOF
[t]
user = nobody
group = nobody
listen = /run/php-t.sock
listen.mode = 0666
pm = static
pm.max_children = 1
EOF
"$prefix/sbin/php-fpm" -t
"$prefix/sbin/php-fpm"
sleep 1
got="$("$prefix/bin/php" -r '
$s = stream_socket_client("unix:///run/php-t.sock"); $p = ["SCRIPT_FILENAME"=>"/srv/t/i.php","REQUEST_METHOD"=>"GET","SERVER_PROTOCOL"=>"HTTP/1.1"];
$rec = function($t,$c){ return pack("CCnnCx",1,$t,1,strlen($c),0).$c; };
$kv = ""; foreach ($p as $k=>$v) $kv .= chr(strlen($k)).chr(strlen($v)).$k.$v;
fwrite($s, $rec(1, pack("nCx5",1,0)).$rec(4,$kv).$rec(4,"").$rec(5,""));
$o = stream_get_contents($s); echo (strpos($o, "fpm '"$ver"'") !== false) ? "yes" : "no";')"
expect "php-fpm runs a page" yes "$got"
kill "$(cat "/run/php-fpm-$mm.pid")" 2> /dev/null || true
rm -f "$prefix/etc/php-fpm.d/t.conf"

[ "$fail" = 0 ] || exit 1
mkdir -p "$out"
tgz="$out/php-${ver}-${el}${suffix}.tar.xz"
tar -C / -cJf "$tgz" "opt/mpn/php/$mm"
ls -l "$tgz"
