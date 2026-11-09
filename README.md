# mpn-nginx-modules

Build scripts and GitHub Actions workflows that make the nginx modules Mini Panel uses (ModSecurity and PageSpeed) for **one fixed nginx version from nginx.org**, on the five systems the panel supports: Ubuntu 22.04, 24.04, 26.04 and Debian 12, 13.

The modules the distributions ship are each built for the nginx version of that distribution (1.18.0, 1.22.1, 1.24.0, 1.26.3, 1.28.3), and nginx refuses a dynamic module built for another version. To use one nginx version everywhere, the modules have to be built for it.

| Workflow | What it does |
|---|---|
| `modsecurity.yml` | Builds ModSecurity-nginx against the source of nginx 1.28.3 with the arguments of the nginx.org package, in a container of each system, loads it into that package and checks that a plain rule and the OWASP Core Rule Set block attacks. |
| `pagespeed.yml` | Builds the PageSpeed module with the build scripts of [We-Amp/mod_pagespeed](https://github.com/We-Amp/mod_pagespeed) against nginx 1.28.3, loads it into the nginx.org package and checks that a page is processed. Slow: Bazel builds the whole engine. |

Everything downloaded is checked against a checksum fixed in the workflow (nginx source, the connector, the PageSpeed release), and the nginx.org package is installed at an exact version with an apt pin and a hold.

## Licences

The scripts and workflows are Apache-2.0. The built modules keep the licences of their sources: ModSecurity-nginx is Apache-2.0, mod_pagespeed is Apache-2.0, nginx is BSD-2-Clause.
