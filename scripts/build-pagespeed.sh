#!/usr/bin/env bash
# Builds ngx_pagespeed_module.so for nginx.org's nginx with the build scripts of We-Amp/mod_pagespeed, inside a container of the target
# distribution, then loads it into the nginx.org package of the same version and checks that PageSpeed rewrites a page.
# Runs on a GitHub-hosted runner (it needs docker).
#   build-pagespeed.sh <distro> <nginx version> <nginx sha256> <We-Amp module tag> <outdir>
# The module is built for the CPU of the runner: an x86-64 runner gives the file with no suffix (the name the panel has always
# used), an arm64 runner gives the file ending in -arm64.
set -euo pipefail
distro="${1:?noble|jammy|bookworm|trixie|resolute}"
ngx="${2:?nginx version}"
ngxsha="${3:?nginx sha256}"
tag="${4:?module tag, such as module-v2.8.1}"
out="${5:?output directory}"
here="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -m)" in
  x86_64) suffix="" ;;
  aarch64) suffix="-arm64" ;;
  *) echo "unsupported CPU $(uname -m)" >&2; exit 2 ;;
esac
name="ngx_pagespeed_module-${distro}-nginx${ngx}${suffix}.so"

# el9 and el10 are built in AlmaLinux; the same file serves Rocky Linux and CentOS Stream of that major version.
case "$distro" in
  jammy) image="ubuntu:22.04"; family=ubuntu ;;
  noble) image="ubuntu:24.04"; family=ubuntu ;;
  resolute) image="ubuntu:26.04"; family=ubuntu ;;
  bookworm) image="debian:12"; family=debian ;;
  trixie) image="debian:13"; family=debian ;;
  el9) image="almalinux:9"; family=el ;;
  el10) image="almalinux:10"; family=el ;;
  *) echo "unknown distro: $distro" >&2; exit 2 ;;
esac
[[ "$ngx" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad nginx version" >&2; exit 2; }
[[ "$ngxsha" =~ ^[0-9a-f]{64}$ ]] || { echo "bad nginx sha256" >&2; exit 2; }
[[ "$tag" =~ ^module-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad module tag" >&2; exit 2; }
ver="${tag#module-v}"

mkdir -p "$out"
tmp="$(mktemp -d)"
base="https://github.com/We-Amp/mod_pagespeed/releases/download/${tag}"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
curl -fsSL -o "$tmp/src.tgz" "$base/mod_pagespeed-${ver}.tar.gz"
want="$(awk -v f="mod_pagespeed-${ver}.tar.gz" '$2==f{print $1}' "$tmp/SHA256SUMS")"
[ -n "$want" ] && [ "$(sha256sum "$tmp/src.tgz" | cut -d' ' -f1)" = "$want" ] || { echo "the source does not match its published checksum" >&2; exit 1; }
echo "source verified: $want"
mkdir -p "$tmp/ws"
tar xzf "$tmp/src.tgz" -C "$tmp/ws" --strip-components=1
rm -f "$tmp/src.tgz"
df -h / | tail -1

# The el10 branch of We-Amp's script writes the x86-64 triplet into its gcc-toolset-15 links (the el9 branch takes the CPU into
# account). On arm64 the same links are needed under the aarch64 names, so the script is corrected here before it runs.
if [ "$distro" = el10 ] && [ "$suffix" = "-arm64" ]; then
  f="$tmp/ws/install/nginx/build_module_in_container.sh"
  n="$(grep -c 'x86_64-linux-gnu\|x86_64-redhat-linux' "$f")"
  # The lines to change are the ones of the el10 branch that make the gcc-toolset-15 folders and links.
  start="$(grep -n '^elif \[ "\${DISTRO}" = "el10" \]; then' "$f" | head -1 | cut -d: -f1)"
  end="$(awk -v s="$start" 'NR > s && /--config=clang-libstdcxx15/ { print NR; exit }' "$f")"
  [ -n "$start" ] && [ -n "$end" ] || { echo "the el10 branch of We-Amp's script was not found" >&2; exit 1; }
  sed -i "${start},${end}s/x86_64-linux-gnu/aarch64-linux-gnu/g; ${start},${end}s/x86_64-redhat-linux/aarch64-redhat-linux/g" "$f"
  echo "el10 arm64: lines ${start} to ${end} of We-Amp's script now use aarch64 ($n x86-64 names in the file before)"
  sed -n "${start},${end}p" "$f" | grep -n 'ln -sfn\|mkdir -p'
  if sed -n "${start},${end}p" "$f" | grep -q x86_64; then echo "x86_64 is still in the el10 branch" >&2; exit 1; fi
fi

mkdir -p "$tmp/ws/out"
cores="$(nproc)"
docker run --rm --init -e HOME=/workspace -e BAZEL_CPUS="$cores" -e MAKE_JOBS="$cores" \
  -e NGX_SRC_MODE_OVERRIDE=vanilla -e NGINX_SRC_VERSION="$ngx" -e NGINX_SRC_SHA256="$ngxsha" \
  -v "$tmp/ws":/workspace -w /workspace "$image" \
  ./install/nginx/build_module_in_container.sh "$distro" -o "/workspace/out/$name"

so="$out/$name"
cp "$tmp/ws/out/$name" "$so"
ls -l "$so"
file "$so" 2> /dev/null || true

# --- test in a clean container of the same distribution -------------------------------------------------------------------------
cp "$here/install-nginx-org.sh" "$here/install-nginx-org-el.sh" "$tmp/"
cat > "$tmp/check.sh" << 'EOS'
set -euo pipefail
codename="$1"; family="$2"; ngx="$3"; so="$4"
if [ "$family" = el ]; then
  bash /t/install-nginx-org-el.sh "$ngx"
else
  bash /t/install-nginx-org.sh "$codename" "$family" "$ngx"
fi
mkdir -p /w/www /w/cache
printf '<html><head></head><body>\n\n   <p>  hello   </p>\n\n<!-- a comment -->\n<img src="/x.png">\n</body></html>\n' > /w/www/index.html
cat > /w/nginx.conf << EOF
load_module $so;
pid /w/nginx.pid;
error_log /w/error.log info;
events { worker_connections 64; }
http {
  access_log off;
  pagespeed FileCachePath /w/cache;
  server {
    listen 127.0.0.1:18082;
    pagespeed on;
    pagespeed RewriteLevel CoreFilters;
    pagespeed EnableFilters remove_comments,collapse_whitespace;
    root /w/www;
  }
}
EOF
nginx -t -c /w/nginx.conf
nginx -c /w/nginx.conf
sleep 2
curl -s -D /w/h.txt -o /w/body.txt http://127.0.0.1:18082/index.html || true
curl -s -D /w/h.txt -o /w/body.txt http://127.0.0.1:18082/index.html
cat /w/h.txt
cat /w/body.txt
nginx -s stop -c /w/nginx.conf || true
grep -qi '^x-page-speed:' /w/h.txt || { echo "FAIL  no X-Page-Speed header: the module did not process the page"; tail -20 /w/error.log; exit 1; }
if grep -q 'a comment' /w/body.txt; then echo "FAIL  the comment was not removed"; exit 1; fi
echo "ok    PageSpeed processed the page"
EOS
docker run --rm -v "$tmp":/t -v "$so":"/t/module.so":ro "$image" bash /t/check.sh "$distro" "$family" "$ngx" /t/module.so
