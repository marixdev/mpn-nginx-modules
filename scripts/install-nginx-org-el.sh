#!/usr/bin/env bash
# Installs nginx from the nginx.org repository at one exact version and locks it, on an EL system (AlmaLinux, Rocky Linux,
# CentOS Stream 9 or 10). Runs as root inside a container of that system.
#   install-nginx-org-el.sh <nginx version>
set -euo pipefail
version="${1:?nginx version, such as 1.28.3}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad nginx version" >&2; exit 2; }

dnf -y -q install ca-certificates curl gnupg2 dnf-plugins-core > /dev/null

# The signing key must be the one nginx.org publishes; dnf then checks every package against it.
curl -fsSL --proto '=https' https://nginx.org/keys/nginx_signing.key -o /tmp/nginx_signing.key
gpg --show-keys --with-colons /tmp/nginx_signing.key | awk -F: '$1=="fpr"{print $10}' > /tmp/nginx-fprs
grep -qx 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 /tmp/nginx-fprs || {
  echo "the nginx.org signing key is not the one this script expects:" >&2
  cat /tmp/nginx-fprs >&2
  exit 1
}
install -m 0644 /tmp/nginx_signing.key /etc/pki/rpm-gpg/RPM-GPG-KEY-nginx
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-nginx

# module_hotfixes lets this repository win over the nginx module stream of the system on EL9.
cat > /etc/yum.repos.d/nginx.repo << 'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-nginx
module_hotfixes=true
EOF

dnf -y -q install "nginx-${version}" > /dev/null
got="$(nginx -v 2>&1)"
echo "$got"
[ "$got" = "nginx version: nginx/${version}" ] || { echo "installed nginx is not ${version}" >&2; exit 1; }
