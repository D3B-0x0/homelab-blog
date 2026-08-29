---
title: "CrowdSec + plain Caddy"
description: "How I run a self-hosted WAF in front of a single plain Caddy container — native CrowdSec tailing Caddy's JSON logs via Docker acquisition, with the nftables bouncer dropping attackers at the kernel."
date: 2026-08-09
tags: [caddy, crowdsec, reverseproxy, selfhosting, waf, security]
---

> **Replicate this if:** you run a plain Caddy reverse proxy in Docker on a VPS
> (see [your first VPS](/posts/2026-08-29-your-first-vps-a-safe-baseline) for
> the floor). Swap `debnerd.in` for your own domain. The CrowdSec part is
> native (systemd), not a container.

## The reverse proxy graveyard

I have a 2GB DigitalOcean VPS running a handful of public services: SearXNG,
Vaultwarden, IT-Tools, Headscale, Forgejo, and their admin consoles. Every one
of them needs HTTPS on port 443, and only one thing can own that port. So I've
spent more time than I'd like admitting on **reverse proxies**. The graveyard,
in order:

1. **Pangolin** (Traefik-based) — the flashy dashboard, container-first, with
   a CrowdSec plugin. Great concept, but I outgrew it fast; it was the first
   thing I deleted when the stack got too clever for itself.
2. **Nginx Proxy Manager Plus** (NPM Plus) — the classic. Web UI, Let's Encrypt
   built in, everyone's first proxy. It worked, but I kept wanting more control
   than the Nginx config model gives you without fighting it.
3. **Caddy Proxy Manager** (CPM) — Caddy under the hood with a web UI. I ran
   this for a while; it's solid. But it's 5+ containers (UI, Caddy, ClickHouse,
   socket-proxy, L4 manager) and I didn't actually *use* the UI — I edited the
   Caddyfile directly anyway.
4. **Plain Caddy** — where I landed. One container, a Caddyfile I own, DNS-01
   certs via Cloudflare. No UI to maintain, no sidecars to babysit. The proxy
   is a solved problem; I stopped making it my hobby.

The pattern across all of them: every proxy was *fine* until it wasn't. The
winning move was the tool with the fewest moving parts *I* had to own. For me
that's plain Caddy + CrowdSec in front.

## Why plain Caddy

- **Caddy, not Nginx.** The site config is declarative and TLS is fully
  automatic. No certbot, no HTTP-01 port-80 dance.
- **DNS-01 via Cloudflare.** I use the `caddy-dns/cloudflare` module, so Caddy
  proves domain ownership through a DNS TXT record. Port 80 stays closed — only
  443 is published. That matters because my VPS sits behind a Cloudflare CDN and
  a DO Cloud Firewall; I don't want port 80 listening at all.
- **One container.** `caddy:2-cloudflare` (xcaddy build with the Cloudflare DNS
  + ratelimit modules). No UI container, no analytics store, no docker-socket
  proxy. Just the proxy.

## The final setup

```
                    ┌──────────────────────────────────────────┐
                    │               VPS (2GB, Debian 13)       │
                    │                                          │
                    │  caddy (plain, :443)        edge-net     │
                    │   searx.debnerd.in  → searxng-core:8080  │
                    │   tools.debnerd.in  → it-tools:8080      │
                    │   vault.debnerd.in  → vaultwarden:80     │
                    │   git.debnerd.in    → forgejo:3000       │
                    │   (…other sites by container name)       │
                    │                                          │
                    │  CrowdSec (native, systemd)              │
                    │   LAPI 127.0.0.1:8090                   │
                    │   nftables bouncer (kernel drops)       │
                    │   docker acquis → caddy container logs   │
                    └──────────────────────────────────────────┘
```

The Caddy container is more than just a proxy — it's the **single sensor**
CrowdSec watches. One stream of JSON access logs, every site covered, zero
per-app changes.

## Caddy: the container

```yaml
# caddy/compose.yml
services:
  caddy:
    image: caddy:2-cloudflare
    restart: unless-stopped
    container_name: caddy
    user: "1000:1000"
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    labels:
      type: caddy          # ← CrowdSec matches on this label
    env_file:
      - .env               # CF_API_TOKEN for DNS-01
    ports:
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    networks:
      edge-net:

networks:
  edge-net:
    external: true
```

Two lines matter for the WAF below:

- `labels: type: caddy` — CrowdSec's Docker acquisition uses this to find the
  container's logs without hard-coding a name.
- **JSON logs to stdout.** CrowdSec's `caddy-logs` parser expects JSON. The
  default Caddy log format is *not* JSON, so you must set it explicitly:

```caddy
# snippet imported by every site
(logging) {
    log {
        output stdout
        format json
    }
}
```

If you skip this, CrowdSec sees Caddy's human-readable log lines and the
`caddy-logs` parser matches nothing — silent, and you'll wonder why nothing
gets banned.

## Caddy: the Caddyfile (skeleton)

```caddy
{
    # DNS-01 via Cloudflare — no port 80 needed for ACME
    dns cloudflare {env.CF_API_TOKEN}
}

(logging) {
    log {
        output stdout
        format json
    }
}

(security_headers) {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Frame-Options "DENY"
        -Server
    }
}

searx.debnerd.in {
    import security_headers
    import logging
    encode zstd gzip
    request_body {
        max_size 10MB
    }
    # Only /search is expensive — rate-limit that, not assets
    rate_limit {
        zone dynamic {
            match {
                path /search
            }
            key    {remote_host}
            events 60
            window 1m
        }
    }
    reverse_proxy searxng-core:8080
}
```

Each site block imports `logging` (JSON to stdout) and `security_headers`
(HSTS, nosniff, etc.). Backends are resolved by container name over the shared
`edge-net` — no published ports except 443. The `rate_limit` block uses the
`caddy-ratelimit` module to cap SearXNG's `/search` at 60 req/min per IP;
tune it per-site so you don't rate-limit static assets by accident.

## CrowdSec: the setup that finally stuck

CrowdSec on this box went through its own graveyard — AppSec-in-a-container,
LAPI-in-a-container, all deleted. The current install is **native** (Debian
packages, systemd), and it's the first one that survived:

- **LAPI** — `crowdsec` 1.7.8, listening on `127.0.0.1:8090`.
- **Firewall bouncer** — `crowdsec-firewall-bouncer-nftables` 0.0.36. It writes
  an `nftables` table with drop rules backed by CrowdSec's blocklists (about
  30K CAPI entries) plus local decisions. Drops happen at the kernel, so banned
  IPs never reach Caddy.
- **Log acquisition** — reads Caddy's container logs through the Docker API:

```yaml
# /etc/crowdsec/acquis.d/setup.caddy.yaml  (on the VPS)
source: docker
container_name:
  - caddy
labels:
  type: caddy
```

CrowdSec (runs as root, can read the Docker socket) tails the Caddy container's
JSON access logs and parses them with `crowdsecurity/caddy-logs`. Every proxied
app gets HTTP attack detection — scanning, probing, CVE exploit attempts —
with zero changes to the Caddy stack. The `labels: type: caddy` here is what
matches the label on the Caddy container above; the `container_name: caddy`
line is a backup matcher.

- **Whitelist** — `/etc/crowdsec/whitelists/whitelisted_ip.yaml` includes
  `100.64.0.0/10` so my Tailscale/headscale mesh (CGNAT space) is never banned
  for SSH or internal traffic.

## The confusing and irritating bits

This is the part that would've saved me hours. In rough order of how much they
annoyed me:

### 1. JSON logs or nothing

The single most common CrowdSec + Caddy failure is forgetting `format json` in
the Caddy `log` block. The `caddy-logs` parser is JSON-only. Human-readable
Caddy logs → parser matches zero lines → no bans, no errors, just silence. Set
`format json` and verify with `docker logs caddy | head` — you should see
`{"level":"info","msg":"handled request",...}`, not plain text.

### 2. Installing the bouncer is a gauntlet

`apt install crowdsec-firewall-bouncer-nftables` will:

- Get **blocked by `apt-listbugs`** on a known start-order bug. Bypass:
  `export APT_LISTBUGS_FRONTEND=none`.
- Hang forever on a **dead SSH pty** via `needrestart` during
  `dpkg --configure`. Kill the chain and re-run detached:
  `DEBIAN_FRONTEND=noninteractive setsid bash -c 'dpkg --configure -a' </dev/null >/dev/null 2>&1 &`
- Prompt to **keep/replace the bouncer yaml** on upgrades. Use
  `dpkg --force-confnew --configure crowdsec-firewall-bouncer-nftables`.

### 3. The bouncer API key mismatch crash-loop

The bouncer reads its key from
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`. If it doesn't match
what LAPI registered (`cscli bouncers list`), the bouncer crash-loops silently.
This bit me twice because it works, then breaks on reinstall when a stale key
lingers. Fix:

```bash
sed -i "s|^api_key: .*|api_key: <key-from-cscli-bouncers-list>|" \
  /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
chmod 600 /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
systemctl restart crowdsec-firewall-bouncer
```

`cscli bouncers list` before you debug anything else — the key mismatch is the
#1 CrowdSec footgun.

### 4. `container_name:` vs `docker_container_name:`

In the docker acquisition config, the field is **`container_name:`**. If you use
`docker_container_name:` (which *looks* right), config validation fails. The
docs changed this at some point and every older blog post is wrong. Use
`container_name:` (or just `labels: type: caddy`, which is what I rely on).

### 5. Probing your own WAF bans your own IP

Want to test that the WAF is live? Curl
`https://searx.debnerd.in/.git/HEAD` from the VPS itself and CrowdSec bans
**the VPS's own IPv6**. It's the AppSec virtual-patching rule doing exactly its
job — on you. Delete with:

```bash
sudo cscli decisions delete -i <your-ipv6>
```

(The bouncer caches decisions for ~15s, so the 403s don't stop instantly — wait
~16s after deleting before retesting.) Prefer `cscli decisions delete --id <n>`
if you have the decision ID; `-i` parses the arg as an IP, not an ID.

### 6. One proxy, not five

The CPM era taught me that "a simple proxy" was actually ClickHouse + a
socket-proxy + an L4 port manager + GeoIP updater on 2GB RAM. Plain Caddy is
one container. If you want analytics, run Beszel or Uptime Kuma separately
(which I do) — don't bolt them onto the proxy. Budget your RAM for the apps,
not the front door.

## Verify it's working

```bash
# on the VPS
sudo cscli metrics          # shows 'caddy-logs' parser lines ingested
sudo cscli decisions list   # active bans
docker logs caddy 2>&1 | head   # should be JSON, not plain text
```

A healthy setup: parser ingest > 0, bans appearing under load, and Caddy logs in
JSON. If `cscli metrics` shows the caddy parser at zero, go back to step 1
(JSON logs) and step 4 (the `container_name`/`labels` matcher).

## What I learned

- Reverse proxies are a solved problem until you make them your hobby. The
  winning move was the fewest moving parts *I* own: one Caddy container + native
  CrowdSec.
- Native CrowdSec > containerized CrowdSec for this box. One systemd unit, no
  orchestration, direct nftables access.
- The Caddy+CrowdSec contract is two lines: `format json` in the log block, and
  `labels: type: caddy` on the container. Get those right and detection just
  works.
- The bouncer key mismatch is the #1 CrowdSec footgun. `cscli bouncers list`
  before you debug anything else.

## Next

- Wire CrowdSec alert notifications (Telegram) so bans aren't only visible in
  logs.
- Document the headscale + AdGuard DNS side of the mesh properly.
- Keep the proxy boring — it's supposed to be.
