#!/usr/bin/env bash
# Tries the "one fixed nginx" plan on a real machine (not a container): installs nginx 1.28.3, loads ModSecurity and PageSpeed, and checks
# that both work together, survive a reload and a restart, and that apt will not move nginx to another version.
#   vm-test.sh <codename> <debian|ubuntu> <nginxorg|distro> <folder with the .so files>
#     nginxorg  nginx 1.28.3 from nginx.org, the two modules built by the workflows of this repository
#     distro    the nginx of the distribution (Ubuntu 26.04 ships 1.28.3), the modules of the distribution and of We-Amp
set -uo pipefail
codename="${1:?codename}"; family="${2:?family}"; mode="${3:?nginxorg or distro}"; mods="${4:?folder}"
NGX=1.28.3
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o DPkg::Lock::Timeout=600 -y -qq)
pass=0; fail=0
ok() { echo "ok    $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1 -> $3 (wanted $2)"; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
here="$(cd "$(dirname "$0")" && pwd)"

echo "== $(. /etc/os-release; echo "$PRETTY_NAME") | $(free -m | awk '/Mem:/{print $2}') MB RAM | kernel $(uname -r) | mode $mode"
command -v cloud-init > /dev/null && cloud-init status --wait > /dev/null 2>&1
"${APT[@]}" update

if [ "$mode" = nginxorg ]; then
  bash "$here/install-nginx-org.sh" "$codename" "$family" "$NGX" > /tmp/install-nginx.log 2>&1 || { tail -20 /tmp/install-nginx.log; bad "nginx.org $NGX could not be installed"; echo "RESULT pass=$pass fail=$fail"; exit 1; }
  rm -f /usr/sbin/policy-rc.d # the container helper blocks service start; a real machine must start nginx
  user=nginx; moddir=/usr/lib/nginx/modules
  "${APT[@]}" install libmodsecurity3t64 modsecurity-crs > /dev/null 2>&1 || "${APT[@]}" install libmodsecurity3 modsecurity-crs > /dev/null 2>&1
  install -m 0644 "$mods"/ngx_http_modsecurity_module-"$codename"-nginx"$NGX".so "$moddir/ngx_http_modsecurity_module.so"
  install -m 0644 "$mods"/ngx_pagespeed_module-"$codename"-nginx"$NGX".so "$moddir/ngx_pagespeed_module.so"
  cat > /etc/nginx/nginx.conf << EOF
user $user;
worker_processes 1;
pid /run/nginx.pid;
load_module $moddir/ngx_http_modsecurity_module.so;
load_module $moddir/ngx_pagespeed_module.so;
events { worker_connections 256; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  error_log /var/log/nginx/error.log warn;
  include /etc/nginx/conf.d/*.conf;
}
EOF
  rm -f /etc/nginx/conf.d/default.conf
else
  "${APT[@]}" install nginx libnginx-mod-http-modsecurity modsecurity-crs > /tmp/install-nginx.log 2>&1 || { tail -20 /tmp/install-nginx.log; bad "distribution packages could not be installed"; echo "RESULT pass=$pass fail=$fail"; exit 1; }
  # the PageSpeed repository, with the signing key checked against the fingerprint the panel uses
  want=DF00E296BE9141CEA5411346F50D6054F10712A0
  curl -fsSL --proto '=https' https://packages.modpagespeed.com/pubkey.gpg -o /tmp/ps.gpg
  got="$(gpg --batch --with-colons --show-keys /tmp/ps.gpg | awk -F: '$1=="fpr"{print $10}' | sort -u)"
  [ "$got" = "$want" ] || { bad "PageSpeed key fingerprint is $got"; echo "RESULT pass=$pass fail=$fail"; exit 1; }
  gpg --dearmor < /tmp/ps.gpg > /usr/share/keyrings/modpagespeed-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/modpagespeed-archive-keyring.gpg] https://packages.modpagespeed.com/apt $codename main" > /etc/apt/sources.list.d/modpagespeed.list
  "${APT[@]}" update
  "${APT[@]}" install nginx-module-pagespeed > /tmp/install-ps.log 2>&1 || { tail -20 /tmp/install-ps.log; bad "nginx-module-pagespeed could not be installed"; echo "RESULT pass=$pass fail=$fail"; exit 1; }
  user=www-data
fi

got="$(nginx -v 2>&1)"
chk "nginx version" "nginx version: nginx/$NGX" "${got%% (*}"
echo "      $(dpkg-query -W -f='nginx ${Version}' nginx), $(dpkg-query -W -f='${Package} ${Version}' 'libmodsecurity3*' 2> /dev/null | head -1)"

mkdir -p /var/www/mpntest /var/cache/ngx_pagespeed /etc/mpntest
chown -R "$user" /var/cache/ngx_pagespeed
printf '<html><head></head><body>\n\n   <p>  hello   </p>\n<!-- a comment -->\n<img src="/x.png">\n</body></html>\n' > /var/www/mpntest/index.html
crs=/etc/modsecurity/crs/crs-setup.conf
[ -f "$crs" ] || crs=$(ls /etc/modsecurity/crs/crs-setup.conf* 2> /dev/null | head -1)
{
  echo "SecRuleEngine On"; echo "SecRequestBodyAccess On"
  [ -n "$crs" ] && echo "Include $crs"
  echo "Include /usr/share/modsecurity-crs/rules/*.conf"
} > /etc/mpntest/main.conf
cat > /etc/nginx/conf.d/mpntest.conf << 'EOF'
pagespeed FileCachePath /var/cache/ngx_pagespeed;
server {
  listen 127.0.0.1:18090;
  root /var/www/mpntest;
  modsecurity on;
  modsecurity_rules_file /etc/mpntest/main.conf;
  pagespeed on;
  pagespeed RewriteLevel CoreFilters;
  pagespeed EnableFilters remove_comments,collapse_whitespace;
  location / { try_files $uri /index.html; }
}
EOF

if nginx -t > /tmp/nginx-t.log 2>&1; then ok "nginx -t with both modules"; else bad "nginx -t"; cat /tmp/nginx-t.log; fi
systemctl enable nginx > /dev/null 2>&1
systemctl restart nginx
sleep 3
chk "nginx is running under systemd" active "$(systemctl is-active nginx)"

probe() {
  chk "normal request" 200 "$(code 'http://127.0.0.1:18090/index.html?page=2')"
  chk "SQL injection blocked" 403 "$(code "http://127.0.0.1:18090/?id=1%27%20OR%20%271%27%3D%271")"
  chk "XSS blocked" 403 "$(code 'http://127.0.0.1:18090/?q=%3Cscript%3Ealert(1)%3C/script%3E')"
  chk "scanner blocked" 403 "$(code -A 'sqlmap/1.7' 'http://127.0.0.1:18090/')"
  curl -s -D /tmp/h.txt -o /tmp/b.txt 'http://127.0.0.1:18090/index.html' > /dev/null
  curl -s -D /tmp/h.txt -o /tmp/b.txt 'http://127.0.0.1:18090/index.html' > /dev/null
  if grep -qi '^x-page-speed:' /tmp/h.txt && ! grep -q 'a comment' /tmp/b.txt; then ok "PageSpeed rewrote the page"; else bad "PageSpeed did not rewrite the page"; cat /tmp/h.txt; fi
}
probe
echo "-- after a reload"; systemctl reload nginx && sleep 2 && probe
echo "-- after a restart"; systemctl restart nginx && sleep 3 && probe

rss="$(ps -o rss= -C nginx | awk '{s+=$1} END {printf "%.0f", s/1024}')"
echo "      nginx memory with both modules and the rule set: ${rss} MB; machine: $(free -m | awk '/Mem:/{print $7}') MB available"
grep -ciE 'emerg|crit|segfault|alert' /var/log/nginx/error.log | sed 's/^/      serious lines in the error log: /'
dmesg 2> /dev/null | grep -ci 'segfault' | sed 's/^/      segfaults in the kernel log: /'

echo "-- version stays put"
cand="$(apt-cache policy nginx | awk '/Candidate:/{print $2}')"
echo "      candidate: $cand; held: $(apt-mark showhold | tr '\n' ' ')"
if "${APT[@]}" -s upgrade 2> /dev/null | grep -q '^Inst nginx'; then bad "apt would change nginx"; else ok "apt upgrade leaves nginx alone"; fi
echo "RESULT $codename $mode pass=$pass fail=$fail"
[ "$fail" = 0 ]
