---
title: "Self-hosting Headscale + Headplane"
description: "Run your own private Tailscale with Headscale and Headplane — a full guide, with a primer for newcomers."
date: 2026-08-09
tags: [headscale, tailscale, vpn, selfhosting, homelab]
---

## Wait, isn't Tailscale already free?

> **Replicate this if:** you have a VPS with Docker + a reverse proxy (see
> [your first VPS](/posts/2026-08-29-your-first-vps-a-safe-baseline) first). You'll also want a Google account for OIDC login, or swap it for any OIDC provider. Replace `debnerd.in` with your domain throughout.

For my setup? Mostly. But this project isn't about saving $5/month — it's about
**who holds the keys to your network**. Tailscale's magic is that it builds a
mesh VPN (WireGuard under the hood) where every device talks to every other
device directly, with no central server in the data path. But the *control
plane* — the part that authenticates devices and decides who can talk to whom —
is a third-party SaaS by default.

> **Update (Sep 2026):** I've since moved my network to Tailscale's cloud
> control plane (one less thing to maintain) — so treat this post as a
> historical build log, not my live setup. The concepts (control vs data plane,
> OIDC allowlists, expiry footguns) all still apply.

I got tired of relying on that third party for a network that carries my
photos, my VPS, my phones and my family's devices. So I self-hosted the control
plane with **Headscale**, and put **Headplane** in front of it for a web UI.

Before the install guide, here's the primer I wish I'd had.

## Tailscale for newcomers

### The problem it solves

You have a laptop, a phone, a tablet, and a VPS in a datacenter on the other
side of the planet. You want them to talk to each other like they're on the
same Wi-Fi — securely, without opening ports or juggling public IPs.

### How it works

Tailscale is built on **WireGuard**, a modern VPN protocol. Each of your
devices runs a small client that generates its own cryptographic keypair. A
device's *identity* is its key, not its IP. This is the crucial bit: your
devices have IPs like `100.99.0.5` that stay the same everywhere, and Tailscale
figures out how to route packets between them — whether they're on the same
LAN, behind different NATs, or on a datacenter IP.

Key concepts you'll keep hearing:

- **Tailnet** — your private network of all your devices (the "mesh").
- **Control plane** — the service that authenticates devices and distributes
  the "who can reach whom" rules. The *brains*.
- **Data plane** — the actual encrypted packets. The *muscle*.
- **MagicDNS** — gives your devices nice names (`immich.ts.example.com`)
  instead of `100.99.0.5`.
- **DERP** — Tailscale's relay servers. When two devices can't punch through
  NAT directly (e.g. both behind strict carrier NAT), traffic bounces through a
  DERP relay. Always encrypted, just slower than a direct path.
- **NAT traversal** — the black magic where two devices behind NAT find each
  other without you opening any ports.

The killer feature: **you open no ports**. Devices connect *out* to the control
plane, and the control plane tells them about each other. Your laptop at a
cafe and your VPS behind a firewall just... find each other.

### The default vs the self-hosted

- **Default Tailscale**: control plane is Tailscale's SaaS. Free tier covers
  up to 100 devices and 3 users. Honestly great — for most people, use it.
- **Headscale**: an open-source implementation of the control plane. You run
  the brains yourself (on a VPS, on a spare machine), and your devices connect
  to *your* server instead of Tailscale's.

Why do it? Control (you hold the auth database, not a SaaS), privacy (no
third-party account linking your devices), learning (you now understand the
whole stack — huge for someone who wants to work in infrastructure), and
independence (Tailscale's servers going down doesn't take your network down —
the mesh keeps working between devices that already know each other).

The tradeoff: you maintain it, you fix it when it breaks, and you own the
security of the control plane. That's exactly why I did it — and why this
blog exists.

## My architecture

```
                     ┌─────────────────────────────────────────────┐
                     │                VPS (Debian 13)               │
                     │                                             │
            Internet ──► Caddy ──► headscale.debnerd.in:8080   │
                     │      │                                      │
                     │      └──────► console.debnerd.in:3050       │
                     │             (Headplane web UI)              │
                     │                                             │
                     │   Headscale (control plane)                 │
                     │    • SQLite database                        │
                     │    • Embedded DERP relay (3478/udp)         │
                     │    • Google OIDC login                      │
                     │                                             │
                     │   AdGuard Home (tailnet DNS, 100.99.0.3)    │
                     └─────────────────────────────────────────────┘
                                   ▲
                     ┌─────────────┴─────────────┐
                     │          tailnet          │
                     │   (100.99.0.0/24 mesh)    │
                     │                           │
                     ▼                           ▼
               Fedora laptop              iPhone / Android / VPS
               Immich server              direct WireGuard peer
```

Key decisions:

- **Headscale does NOT own public ports** (except 3478/udp for the embedded
  DERP/STUN). Caddy terminates TLS and proxies to the container by name over a
  shared Docker network. This means one reverse proxy + one WAF (CrowdSec)
  fronts *everything*.
- **Google OIDC for login** — sign in with Gmail, no separate username/
  password to manage. Access is allowlisted by email, not by domain.
- **AdGuard Home is the tailnet DNS** — my devices resolve MagicDNS names
  AND get ad-blocking from a single nameserver on the tailnet.
- **Tailscale's public DERP map is kept as a relay fallback** for the worst
  NAT cases, but my embedded DERP region runs first.

## Prerequisites

- A Linux server (I use a Debian 13 VPS) with Docker + Docker Compose.
- A domain name with a DNS record pointing at your server. I use two hostnames
  under `debnerd.in`: `headscale.debnerd.in` and `console.debnerd.in`.
- A reverse proxy in front (Caddy / nginx) to terminate TLS — Headscale itself
  doesn't handle HTTPS here.
- (Optional but recommended) Google Cloud project for OIDC login.

## Step 1: directory layout

Headscale and Headplane share a directory. Critical detail I learned the hard
way: **the compose file uses relative paths, so always run `docker compose`
from this exact directory** — I'll come back to that in the pitfalls below.

```
Headscale/
├── compose.yml
├── .env                 # secrets (chmod 600, never commit)
├── config/
│   └── config.yaml      # headscale config
├── headplane_config/
│   └── config.yaml      # headplane config
├── lib/                 # headscale data (db.sqlite, keys)
└── headplane_lib/       # headplane data
```

## Step 2: compose.yml

```yaml
services:
  headscale:
    image: headscale/headscale:stable
    restart: unless-stopped
    env_file:
      - .env
    container_name: headscale
    labels:
      me.tale.headplane.target: headscale
    volumes:
      - ./config:/etc/headscale
      - ./lib:/var/lib/headscale
      - ./run:/var/run/headscale
    command: serve
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    networks:
      edge-net:
    ports:
      - "3478:3478/udp"

  headplane:
    image: ghcr.io/tale/headplane:latest
    restart: unless-stopped
    container_name: headplane
    environment:
      CONFIG_FILE: "/etc/headplane/config.yaml"
    env_file:
      - .env
    volumes:
      - ./headplane_config:/etc/headplane
      - ./headplane_lib:/var/lib/headplane
      - ./config:/etc/headscale:rw
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      edge-net:

networks:
  edge-net:
    external: true
```

Notes:

- `3478/udp` is the only published port — that's the embedded DERP/STUN
  listener. Everything else is container-to-container.
- Headplane mounts the Docker socket **read-only** (it needs it to manage the
  headscale container) and mounts headscale's config directory so it can edit
  ACLs / policy.
- I share an external Docker network with my reverse proxy. If you don't have
  a custom network, replace this with `bridge` + published ports for 8080 and
  3050 (and handle TLS however your proxy likes).

## Step 3: .env (secrets)

Headscale and Headplane both read env overrides. Keep this file `chmod 600`
and never commit it:

```bash
# headscale
HEADSCALE_OIDC_CLIENT_SECRET=<your-google-client-secret>

# headplane — double underscores = nested keys
HEADPLANE_LOAD_ENV_OVERRIDES=true
HEADPLANE_SERVER__COOKIE_SECRET=<exactly-32-chars>
HEADPLANE_OIDC__CLIENT_SECRET=<your-google-client-secret>
HEADSCALE_API_KEY=<generated-with-headscale-command>
```

The env-override convention: headscale uses `HEADSCALE_<KEY>` with dots →
underscores; headplane uses `HEADPLANE_<SECTION>__<KEY>` with double
underscores. Both are documented in their respective READMEs.

## Step 4: headscale config.yaml

```yaml
server_url: https://headscale.debnerd.in
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: true
trusted_proxies:
  - 172.22.0.0/16

prefixes:
  v4: 100.99.0.0/24
  v6: fd7a:115c:a1e0::/48
allocation: sequential

derp:
  server:
    enabled: true
    region_id: 999
    region_code: headscale
    region_name: Headscale Embedded DERP
    verify_clients: true
    stun_listen_addr: 0.0.0.0:3478
    automatically_add_embedded_derp_region: true
    ipv4: <your-public-ipv4>
    ipv6: <your-public-ipv6>
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  auto_update_enabled: true
  update_frequency: 3h

node:
  expiry: 0

dns:
  magic_dns: true
  base_domain: ts.debnerd.in
  override_local_dns: true
  nameservers:
    global:
      - 100.99.0.3        # my AdGuard Home on the tailnet
      - 1.1.1.3
      - 1.0.0.3

oidc:
  issuer: https://accounts.google.com
  client_id: <your-google-client-id>
  use_expiry_from_token: false
  scope: [openid, profile, email]
  email_verified_required: true
  allowed_domains: []
  allowed_users:
    - you@gmail.com
    - partner@gmail.com
  pkce:
    enabled: true
    method: S256

policy:
  mode: database
```

Decisions worth explaining:

- **`trusted_proxies: [172.22.0.0/16]`** — my reverse proxy's Docker network.
  Headscale needs to know which proxy IPs to trust so it sees the *real* client
  IPs, not the proxy's.
- **`grpc_listen_addr: 127.0.0.1`** — the gRPC API is loopback-only. When I
  first set this up it was `0.0.0.0` and that's an exposed API with no auth if
  anything else can reach the host. Loopback + the docker socket mount is how
  headplane talks to it.
- **`node.expiry: 0`** — new nodes never expire. Default is 180 days; I found
expiry biting me exactly when a device was least convenient. See Pitfall 4 for
the per-node command.
- **`verify_clients: true`** on the embedded DERP — only authenticated clients
  get relay service. Raw STUN probes time out by design.
- **`allowed_users` allowlist** — the OIDC *only* lets these exact emails in.
  `allowed_domains: []` means no wildcard "anyone @ mydomain" access. This is
  the "who holds the keys" control made concrete: even someone with a Google
  account for the right domain can't join.
- **`policy.mode: database`** — ACLs are editable from the Headplane UI
  instead of a static file.

## Step 5: headplane config.yaml

```yaml
server:
  host: 0.0.0.0
  port: 3050
  cookie_secure: true
  cookie_max_age: 86400
base_url: https://headscale.debnerd.in
headscale:
  url: http://headscale:8080
  config_path: /etc/headscale/config.yaml
oidc:
  enabled: true
  issuer: https://accounts.google.com
  client_id: <your-google-client-id>
  use_pkce: true
  scope: openid email profile
  default_role: admin
  profile_picture_source: oidc
  use_end_session: true
  post_logout_redirect_uri: https://headscale.debnerd.in/admin/login?s=logout
  token_endpoint_auth_method: client_secret_post
  extra_params:
    prompt: select_account
```

Headplane is the web UI: users, nodes, ACLs, pre-auth keys, routes. The
`cookie_secret` (in `.env` via `HEADPLANE_SERVER__COOKIE_SECRET`) must be
**exactly 32 characters** — a 44-char base64 string will fail validation
silently and confuse you for an hour.

## Step 6: Google OIDC setup

1. Go to [console.cloud.google.com](https://console.cloud.google.com) → create
    a project.
2. **APIs & Services → OAuth consent screen** → External → add your test users
    (the emails you put in `allowed_users`).
3. **Credentials → Create Credentials → OAuth client ID** → Web application.
4. Authorized redirect URIs — Headscale uses `/oidc/callback`:
    - `https://headscale.debnerd.in/oidc/callback`
    - Headplane uses `/admin/api/oidc/callback`:
    - `https://headscale.debnerd.in/admin/api/oidc/callback`
5. Copy the client ID into both configs and the client secret into `.env`.

## Step 7: first boot

```bash
cd ~/Headscale
docker compose up -d
docker logs -f headscale
```

If both containers come up healthy, create your first user:

```bash
docker exec headscale headscale users create you@gmail.com
```

Generate a pre-auth key for headless devices (servers, sidecars):

```bash
docker exec headscale headscale preauthkeys create --user you@gmail.com
```

## Step 8: join devices

**Linux** (my Fedora laptop):

```bash
sudo tailscale up --login-server https://headscale.debnerd.in
```

It prints an auth URL — open it, sign in with Google, done. The machine is now
a tailnet node at `100.99.0.1`.

**iOS / Android**: in the official Tailscale app, tap the account menu and
choose "Use an alternate login server" → enter
`https://headscale.debnerd.in`.

**Headless servers** (my Immich sidecar): use a pre-auth key:

```bash
sudo tailscale up --login-server https://headscale.debnerd.in \
  --auth-key <preauth-key>
```

## Step 9: DNS and nameservers

Headscale advertises MagicDNS to all clients: `base_domain: ts.debnerd.in`
means my Immich server is `immich.ts.debnerd.in`, resolving to `100.99.0.5`.

The `nameservers.global` list is what clients use to resolve *everything else*.
My first entry is my own **AdGuard Home** on the tailnet — so every device
gets ad-blocking DNS with zero client config. The rest are Cloudflare DoH
fallbacks. One pitfall: your nameserver must be reachable on the tailnet, and
if you use ACLs, the clients need a rule that allows them to reach the DNS
server.

## Step 10: stop, and don't do this

**Verify what you actually have.** My earlier setup has taught me more through
breakage than through success, so let me save you the pain. The two things
that bit me hardest:

### Pitfall 1: the crash-loop from a wrong working directory

```
docker compose up -d
```

run from the wrong directory (say, a stale copy of the folder) makes Docker
auto-create **empty, root-owned directories** for your relative mounts
(`./config`, `./lib`, `./run`). Both containers then crash-loop with
"no config file found" / "Could not access config file". The fix is
`docker rm -f headscale headplane` then re-run compose from the *real*
directory. Your data was never lost — the phantom dirs just shadowed the real
mounts.

**Rule: always `docker compose` from `~/Headscale/`.**

### Pitfall 2: distroless containers

Headscale and Headplane containers have **no shell**. No `sh`, no `grep`, no
`sed`. Want to inspect config? `docker exec headscale headscale --help` works
(the binary is the entrypoint), but `docker exec headscale grep ...` does not.
Use the host's tools against the mounted directories instead:

```bash
grep expiry /home/ghostvps/Headscale/config/config.yaml
```

### Pitfall 3: the 32-char cookie secret

`HEADPLANE_SERVER__COOKIE_SECRET` must be exactly 32 characters. Generate one
with `openssl rand -base64 24` and strip to 32, or `tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32`.

### Pitfall 4: expiry is a footgun until you disable it

Default `node.expiry` is 180 days. When I looked, my three *newest* nodes
(the ones I cared about most) had expiry dates set; my three oldest had none.
If a device's key expires, it silently falls off the mesh and re-auths with a
banner you might not notice. For a personal network:

```yaml
node:
  expiry: 0
```

And to clear expiry on already-registered nodes:

```bash
docker exec headscale headscale nodes expire -d -i <node-id>
```

Tradeoff to accept: nothing expires anymore, so a lost/stolen device has no
safety net — delete it manually when it's gone.

### Pitfall 5: AdGuard Home as tailnet DNS

If your nameserver is a container on the tailnet, it must be reachable from
clients (and allowed by ACLs). I bind AdGuard to my VPS node's tailnet IP
(`100.99.0.3:53`), not to a host port — so DNS is tailnet-only and never
exposed publicly.

## Post-install: ACLs and admin

With `policy.mode: database`, open
`https://console.debnerd.in` (or wherever your headplane UI lives), sign in
with Google, and you get the full dashboard: nodes, users, pre-auth keys,
routes, and an ACL editor.

My ACL shape: an `admins` group with my email, tagged nodes (`tag:server`,
`tag:exit-node`), and rules like *admins → everything*, *clients → Immich on
2283*, *clients → DNS on 53*. Nothing more permissive than it needs to be.

## What I learned

- The control plane is the interesting part of a mesh VPN. The data plane is
  just encrypted packets; *auth and policy* are where the real trust lives.
- Self-hosting the control plane flips a SaaS dependency into an
  infrastructure responsibility — which is exactly the kind of thing I want to
  be good at.
- `allowed_users` > `allowed_domains` for a family network. Exact allowlists,
  nothing wildcard.
- Containers that look like Linux but have no shell are a different kind of
  beast — mount the config dir and use host tools.

## Next

- Wire up Taildrop (already enabled) for easy file transfers to phones.
- Explore exit-node routing so a device can use the VPS as an egress.
- Document the full CrowdSec + Caddy setup that terminates TLS for everything
  on this tailnet.