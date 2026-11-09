#!/usr/bin/env bash
# Installs nginx from the nginx.org repository at one exact version and pins it, so nothing upgrades it by itself.
# Runs as root inside a Debian or Ubuntu container.
#   install-nginx-org.sh <codename> <debian|ubuntu> <nginx version>
set -euo pipefail
codename="${1:?codename, such as noble}"
family="${2:?debian or ubuntu}"
version="${3:?nginx version, such as 1.28.3}"

case "$family" in debian | ubuntu) ;; *) echo "family must be debian or ubuntu" >&2; exit 2 ;; esac
[[ "$codename" =~ ^[a-z]+$ ]] || { echo "bad codename" >&2; exit 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad nginx version" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
# A container has no init system: stop the package from trying to start the server.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update -qq
apt-get install -y -qq --no-install-recommends curl gnupg ca-certificates

# The signing key must be one of the keys nginx.org publishes; apt then checks the repository against it.
curl -fsSL --proto '=https' https://nginx.org/keys/nginx_signing.key -o /tmp/nginx_signing.key
gpg --show-keys --with-colons /tmp/nginx_signing.key | awk -F: '$1=="fpr"{print $10}' > /tmp/nginx-fprs
grep -qx 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 /tmp/nginx-fprs || {
  echo "the nginx.org signing key is not the one this script expects:" >&2
  cat /tmp/nginx-fprs >&2
  exit 1
}
gpg --dearmor < /tmp/nginx_signing.key > /usr/share/keyrings/nginx-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/${family} ${codename} nginx" \
  > /etc/apt/sources.list.d/nginx.list
printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n\nPackage: nginx\nPin: version %s-1~%s\nPin-Priority: 1001\n' \
  "$version" "$codename" > /etc/apt/preferences.d/99nginx

apt-get update -qq
apt-get install -y -qq "nginx=${version}-1~${codename}"
apt-mark hold nginx > /dev/null

got="$(nginx -v 2>&1)"
echo "$got"
[ "$got" = "nginx version: nginx/${version}" ] || { echo "installed nginx is not ${version}" >&2; exit 1; }
