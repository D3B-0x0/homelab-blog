---
title: "CrowdSec + Caddy Proxy Manager"
description: "Why I stopped juggling reverse proxies — from Pangolin to NPM Plus to a custom Caddy to Caddy Proxy Manager, and the CrowdSec setup that finally stuck."
date: 2026-08-09
tags: [caddy, crowdsec, reverseproxy, selfhosting]
---

## The reverse proxy graveyard

> **Replicate this if:** you have a VPS running Docker with a domain pointed at
> it (see [your first VPS](/posts/2026-08-29-your-first-vps-a-safe-baseline)).
> Caddy Proxy Manager replaces your existing proxy — read before you switch,
> don't run it blind next to NPM/Pangolin.

I have a 2GB DigitalOcean VPS running a handful of public services: SearXNG,
Vaultwarden, IT-Tools, Headscale, and their admin consoles. Every one of them
needs HTTPS on port 443, and only one thing can own that port. So I've spent
more time than I'd like admitting on **reverse proxies**. The graveyard, in
order:

1. **Pangolin** (Traefik-based) — the flashy dashboard, container-first, with
   a CrowdSec plugin. Great concept, but I outgrew it fast; it was the first
   thing I deleted when the stack got too clever for itself.
2. **Nginx Proxy Manager Plus** (NPM Plus) — the classic. Web UI, Let's Encrypt
   built in, everyone's first proxy. It worked, but I kept wanting more control
   than the Nginx config model gives you without fighting it.
3. **Custom Caddy build** (Caddy + CrowdSec module + Cloudflare DNS provider)
   — my hand-rolled era. A 158MB image, a hand-written Caddyfile with a
   `crowdsec` block, ACME via Cloudflare DNS. This taught me Caddy, and Caddy
   is *good* — but maintaining a custom image and a Caddyfile by hand is a
   whole job.

The pattern: every proxy was *fine* until it wasn't. I wanted the web UI of
NPM, the correctness of Caddy, and CrowdSec WAF in front of everything
without gluing modules into custom builds.

That's **Caddy Proxy Manager** (CPM) — an open-source, Caddy-based drop-in
NPM replacement. Caddy under the hood (automatic HTTPS, sane config), web UI
on top, and since it's Caddy, CrowdSec parses its logs natively.

## Why CPM, specifically

- **Caddy, not Nginx.** Caddy's site config is declarative and its TLS is
  fully automatic (Let's Encrypt, HTTP-01, no certbot chores). Everything NPM
  made me fight in Nginx syntax became a Caddyfile directive.
- **Web UI for proxy hosts.** Add `vault.debnerd.in → vaultwarden:80` from a
  form, not by editing a file and reloading.
- **CrowdSec-native.** CrowdSec ships a `crowdsecurity/caddy-logs` parser. Feed
  it the Caddy container's logs and you get HTTP attack detection (scanning,
  probing, CVEs) across *all* your apps with zero per-app changes.
- **It's maintained.** The NPM Plus fork era was messy; CPM is actively
  developed and, importantly, Docker-first — which is how my whole VPS runs.

## The final setup

```
                    ┌──────────────────────────────────────────┐
                    │               VPS (2GB, Debian 13)       │
                    │                                          │
                    │  CPM stack (host ports 80/443/2019)      │
                    │  ┌──────────────────────────────────┐    │
                    │  │ caddy (Caddy Proxy Manager)      │    │
                    │  │  searx.debnerd.in  → searxng-core:8080 │
                    │  │  tools.debnerd.in  → it-tools:8080     │
                    │  │  vault.debnerd.in  → vaultwarden:80    │
                    │  │  headscale.debnerd.in → headscale:8080 │
                    │  │  console.debnerd.in → headplane:3050   │
                    │  └──────────────────────────────────┘    │
                    │                                          │
                    │  CrowdSec (native)                       │
                    │   LAPI 127.0.0.1:8090                    │
                    │   nftables bouncer (kernel drops)        │
                    │   docker acquis → caddy container logs   │
                    └──────────────────────────────────────────┘
```

The CPM stack is more than one container:

```
caddy-proxy-manager-web          # the UI (port 3000, tailnet-only)
caddy-proxy-manager-l4-ports     # L4 port manager (non-HTTP proxying)
caddy-proxy-manager-caddy        # the actual proxy (80/443/2019)
caddy-proxy-manager-clickhouse   # analytics storage
caddy-proxy-manager-docker-proxy # docker-socket-proxy (the ONLY socket access)
geoipupdate-caddy                # MaxMind GeoIP updates
```

Notice: **no container gets the raw Docker socket except the docker-socket
proxy** (a hardened filter). That's a security detail I really like — the UI
container talks to `docker-proxy`, not `/var/run/docker.sock` directly.

Proxied containers join an external network I share with the stack:

```yaml
networks:
  caddy-proxy-manager_caddy-network:
    external: true
```

That's how Headscale (which publishes no host ports at all, not even 8080)
is reachable: Caddy proxies to `headscale:8080` by container name over the
shared network, and `3478/udp` stays the only port Headscale publishes.

## CrowdSec: the setup that finally stuck

CrowdSec history on this box is also a graveyard — container with AppSec WAF
(serving the old custom Caddy), container with LAPI + AppSec, all deleted.
The current install is **native** (Debian packages, systemd), and it's the
first one that survived:

- **LAPI** — `crowdsec` 1.7.8, listening on `127.0.0.1:8090`.
- **Firewall bouncer** — `crowdsec-firewall-bouncer-nftables` 0.0.36. It writes
  an `nftables` table with drop rules backed by CrowdSec's blocklists
  (about 30K CAPI entries) plus local decisions.
- **Log acquisition** — `/etc/crowdsec/acquis.d/setup.caddy.yaml`:

```yaml
source: docker
container_name:
  - caddy-proxy-manager-caddy
labels:
  type: caddy
```

CrowdSec (runs as root, can read the Docker socket) tails the CPM Caddy
container's JSON access logs through the Docker API and parses them with
`crowdsecurity/caddy-logs`. Every proxied app gets HTTP attack detection with
zero changes to the CPM stack.

- **Whitelist** — `/etc/crowdsec/whitelists/whitelisted_ip.yaml` includes
  `100.64.0.0/10` so my Tailscale/headscale mesh (which uses CGNAT space) is
  never banned for SSH.

## The confusing and irritating bits

This is the part that would've saved me hours. In rough order of how much they
annoyed me:

### 1. Installing the bouncer is a gauntlet

`apt install crowdsec-firewall-bouncer-nftables` will:

- Get **blocked by `apt-listbugs`** on a known start-order bug. Bypass:
  `export APT_LISTBUGS_FRONTEND=none`.
- Hang forever on a **dead SSH pty** via `needrestart` during
  `dpkg --configure`. Kill the chain and re-run detached:
  `DEBIAN_FRONTEND=noninteractive setsid bash -c 'dpkg --configure -a' </dev/null >/dev/null 2>&1 &`
- Prompt to **keep/replace the bouncer yaml** on upgrades. Use
  `dpkg --force-confnew --configure crowdsec-firewall-bouncer-nftables`.

### 2. The bouncer API key mismatch crash-loop

The bouncer reads its key from
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`. If it doesn't match
what LAPI has registered (`cscli bouncers list`), the bouncer crash-loops
silently. This bit me twice — 08-04 and 08-07, because it's the kind of thing
that works, then breaks on reinstall when a stale key lingers. Fix:

```bash
sed -i "s|^api_key: .*|api_key: <key-from-cscli-bouncers-list>|" \
  /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
chmod 600 /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
systemctl restart crowdsec-firewall-bouncer
```

### 3. `container_name:` vs `docker_container_name:`

In the docker acquisition config, the field is **`container_name:`**. If you
use `docker_container_name:` (which *looks* right), config validation fails.
The docs changed this at some point and every blog post from before then is
wrong.

### 4. Probing your own WAF bans your own IP

Want to test that the WAF is live? Curl
`https://searx.debnerd.in/.git/HEAD` from the VPS itself and CrowdSec bans
**the VPS's own IPv6**. It's the appsec virtual-patching rule doing exactly
its job — on you. Delete with:

```bash
sudo cscli decisions delete -i <your-ipv6>
```

And remember the bouncer caches decisions for ~15s, so the 403s don't stop
instantly.

### 5. CPM sidecars are a surprise the first time

ClickHouse for analytics, a socket proxy, an L4 port manager, geoip updates —
for a "simple" proxy that's a lot of containers on 2GB RAM. It all fits, but
budget for it and don't panic when the stack isn't one container.

### 6. Headscale port confusion

The old NPM era had Headscale published on host ports. With CPM, publish
**nothing** except `3478/udp` (DERP/STUN) — proxy to the container name over
the shared network. This took me a restart-loop to internalize, and it's
covered in my other post.

## What I learned

- Reverse proxies are a solved problem until you make them your hobby. The
  winning move was picking the tool with the fewest moving parts *I* had to
  own: Caddy's TLS + CPM's UI + CrowdSec's native install.
- Native CrowdSec > containerized CrowdSec for this box. One systemd unit,
  no orchestration, direct nftables access.
- Docker socket exposure is a design decision, and the
  docker-socket-proxy pattern is the right answer — least privilege even
  inside your own stack.
- The bouncer key mismatch is the #1 CrowdSec footgun. `cscli bouncers list`
  before you debug anything else.

## Next

- Wire CrowdSec alert notifications (Telegram) so bans aren't only visible in
  logs.
- Set up CPM's GeoIP/analytics properly or disable them to reclaim RAM.
- Document the headscale + AdGuard DNS side of the mesh properly.
