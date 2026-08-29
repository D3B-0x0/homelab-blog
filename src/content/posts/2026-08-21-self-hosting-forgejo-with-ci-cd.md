---
title: "Self-hosting Forgejo with CI/CD"
description: "A complete guide to deploying Forgejo with Docker-in-Docker Actions runners, OIDC login, and email — including every gotcha I hit."
date: 2026-08-21
tags: [forgejo, git, ci-cd, docker, selfhosting, homelab]
---

## Why self-host a Git forge?

> **Replicate this if:** you have a VPS with Docker + a reverse proxy (see
> [your first VPS](/posts/2026-08-29-your-first-vps-a-safe-baseline) and
> [Caddy Proxy Manager](/posts/2026-08-09-crowdsec-and-caddy-proxy-manager)
> first). Swap `git.debnerd.in` for your own domain. Everything else is
> copy-paste.

GitHub is great. But I wanted:

- **Full control** over my code, my data, my CI/CD
- **No vendor lock-in** — code lives on my VPS, mirrored to GitHub
- **Friends can register** via Google/GitHub OIDC and push code
- **CI/CD that actually runs on my infrastructure**, not someone else's

Forgejo is a lightweight, self-hosted Gitea fork. It does everything GitHub
does — issues, PRs, Actions CI/CD, OIDC, packages — and runs on a single
Docker Compose stack.

## Architecture

```
Internet → Caddy (TLS) → Forgejo (:3000)
                         → SSH (:2222)

Forgejo ←── DinD runner ←── Docker-in-Docker daemon
   │
   └── PostgreSQL (edge-net only)
```

Key decision: **Docker-in-Docker (DinD)** for CI/CD, not host Docker socket.
This isolates CI jobs from the host — they can't see your other containers or
data. The tradeoff is that CI containers can't resolve internal hostnames
(like `forgejo`), so the runner config uses the public URL.

## Prerequisites

- A Linux server with Docker + Docker Compose
- A domain name with a DNS record pointing at your server
- A reverse proxy in front (Caddy / nginx) to terminate TLS
- (Optional) Google/GitHub OAuth apps for OIDC login
- (Optional) Brevo account for email (free 300/day)

## Directory layout

```
forgejo/
├── compose.yml           # main stack
├── .env                  # POSTGRES_PASSWORD (chmod 600)
├── runner-config.yml     # runner labels + server connection
├── data/                 # Forgejo app data
├── postgres-data/        # PostgreSQL data
└── runner-data/          # runner cache
```

## compose.yml

```yaml
name: forgejo

services:
  forgejo:
    container_name: forgejo
    image: codeberg.org/forgejo/forgejo:16
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - FORGEJO__database__DB_TYPE=postgres
      - FORGEJO__database__HOST=db:5432
      - FORGEJO__database__NAME=forgejo
      - FORGEJO__database__USER=forgejo
      - FORGEJO__database__PASSWD=${POSTGRES_PASSWORD}
      - FORGEJO__server__ROOT_URL=https://git.debnerd.in
      - FORGEJO__server__HTTP_PORT=3000
      - FORGEJO__server__DOMAIN=git.debnerd.in
      - FORGEJO__server__SSH_DOMAIN=git.debnerd.in
      - FORGEJO__server__SSH_LISTEN_PORT=22
      - FORGEJO__server__SSH_PORT=2222
      # OIDC
      - FORGEJO__openid__ENABLE_OPENID_SIGNIN=true
      - FORGEJO__openid__ENABLE_OPENID_SIGNUP=true
    volumes:
      - ./data:/data
    ports:
      - "2222:22"
    networks:
      edge-net:

  db:
    container_name: forgejo-db
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=forgejo
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=forgejo
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks:
      edge-net:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U forgejo"]
      interval: 10s
      timeout: 5s
      retries: 5

  dind:
    image: docker:27-dind
    container_name: forgejo-dind
    privileged: true
    restart: unless-stopped
    command: ["dockerd", "-H", "tcp://0.0.0.0:2375", "--tls=false"]
    networks:
      edge-net:

  runner:
    container_name: forgejo-runner
    image: data.forgejo.org/forgejo/runner:13
    restart: unless-stopped
    depends_on:
      dind:
        condition: service_started
    links:
      - dind
    environment:
      DOCKER_HOST: tcp://dind:2375
    volumes:
      - ./runner-data:/data
      - ./runner-config.yml:/config.yml:ro
    networks:
      edge-net:
    command: '/bin/sh -c "sleep 5; forgejo-runner daemon --config /config.yml"'

networks:
  edge-net:
    external: true
```

## runner-config.yml

```yaml
log:
  level: info
  job_level: info

runner:
  file: .runner
  capacity: 1
  envs: {}
  timeout: 3h
  labels:
    - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:runner-latest"
    - "ubuntu-22.04:docker://ghcr.io/catthehacker/ubuntu:runner-22.04"
    - "ubuntu-24.04:docker://ghcr.io/catthehacker/ubuntu:runner-24.04"
    - "node-lts:docker://ghcr.io/catthehacker/ubuntu:runner-latest"

cache:
  enabled: true

# DinD: CI containers run inside dockerd, can't resolve internal hostnames.
# Server URL must be the public address so git clones go through Caddy.
server:
  connections:
    git.debnerd.in:
      url: https://git.debnerd.in
```

The runner labels map GitHub Actions runner names to actual Docker images.
When a workflow says `runs-on: ubuntu-latest`, Forgejo pulls
`ghcr.io/catthehacker/ubuntu:runner-latest` inside the DinD container.

## First boot

1. Create `.env`:
   ```bash
   echo "POSTGRES_PASSWORD=$(openssl rand -base64 32)" > .env
   chmod 600 .env
   ```

2. Start the stack:
   ```bash
   docker compose up -d
   ```

3. Visit `https://git.debnerd.in` — the first-run wizard creates your admin
   account and configures the database.

4. During setup, check:
   - **Require email confirmation to register** ✅
   - **Enable email notifications** ✅

## Register the runner

After the first-run wizard, the runner needs a registration token.

1. Go to **Site Administration → Actions → Runners**
2. Copy the registration token
3. The runner will auto-connect on next restart (it waits 5 seconds for
   Forgejo to be ready)

## Email setup (Brevo on port 2525)

I use DigitalOcean, which blocks outbound SMTP on ports 25, 587, and 465.
Port 2525 is the only one that works. Brevo (formerly Sendinblue) supports
it — free tier is 300 emails/day, no credit card.

1. Sign up at [brevo.com](https://www.brevo.com)
2. Go to **SMTP & API → SMTP** → create SMTP credentials
3. In Forgejo, go to **Site Administration → Configuration → SMTP Mailer**
4. Fill in:
   - SMTP Server: `smtp-relay.brevo.com`
   - SMTP Port: `2525`
   - Authentication: Normal password
   - Username: (your Brevo SMTP login)
   - Password: (your Brevo SMTP password)
   - From Address: `noreply@your-domain.com`
   - Enable TLS: STARTTLS

### The gotcha: Forgejo tries implicit TLS by default

After saving, test by clicking **Forgot Password** on the login page. If you
get this error in the logs:

```
tls: first record does not look like a TLS handshake
```

Forgejo is trying port-465-style implicit TLS on port 2525. Fix by adding
`PROTOCOL = smtp+starttls` to the config:

```bash
docker exec forgejo sed -i '/^\[mailer\]/a PROTOCOL = smtp+starttls' /data/gitea/conf/app.ini
docker compose restart forgejo
```

The setup wizard doesn't set this correctly. You have to patch it manually
every time you re-deploy.

## Domain verification for email

Brevo requires DNS records to verify your domain. Add these to your DNS
provider:

```
Type    Name                              Content
TXT     git                               brevo-code:<your-code>
CNAME   brevo1._domainkey.git             b1.<your-domain>.dkim.brevo.com
CNAME   brevo2._domainkey.git             b2.<your-domain>.dkim.brevo.com
TXT     _dmarc.git                        v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com
CNAME   noreply.git                       noreply-<your-domain>.brand.brevosend.com
CNAME   r.noreply.git                     noreply-<your-domain>.r.brand.brevosend.com
CNAME   img.noreply.git                   noreply-<your-domain>.img.brand.brevosend.com
```

All DNS-only (not proxied through Cloudflare). Click **Verify** in Brevo
after adding them.

## OIDC (Google + GitHub)

In Forgejo: **Site Administration → Authentication → Add Authentication Source**

### Google OAuth

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a project → **APIs & Services → OAuth consent screen** → External
3. **Credentials → Create OAuth client ID** → Web application
4. Authorized redirect URI: `https://git.debnerd.in/user/oauth2/callback`
5. Copy Client ID + Secret into Forgejo

### GitHub OAuth

1. Go to [github.com/settings/developers](https://github.com/settings/developers)
2. **New OAuth App**
3. Authorization callback URL: `https://git.debnerd.in/user/oauth2/callback`
4. Copy Client ID + Client Secret into Forgejo

## Push mirroring to GitHub

Since Forgejo is my primary, GitHub is just a mirror. But GitHub Pages
deployment needs GitHub Actions, which needs pushes to GitHub. Push mirroring
solves both.

Per-repo: **Settings → Packages and Mirrors → Mirror Repository**

- Address: `https://github.com/you/repo.git`
- Username: (your GitHub username)
- Password: (a PAT with `repo` scope)
- Enable Push Mirror ✅
- Sync on Commit ✅

Now: push to Forgejo → auto-mirrors to GitHub → GitHub Actions runs → Pages
deploys. Everything just works.

## Gotchas

### 1. DinD can't resolve internal hostnames

CI containers run inside Docker-in-Docker, which has its own network
namespace. They can't reach `forgejo`, `db`, or any other container by name.
That's why `runner-config.yml` uses the public URL — git clones go through
Caddy (public DNS) and it works fine.

### 2. Runner data directory permissions

The runner container runs as uid 1000 (non-root). If `runner-data/` is
owned by root, the runner can't create its cache directory. Fix:

```bash
sudo chown -R 1000:1000 forgejo/runner-data
```

### 3. WebAuthn blocks API basic auth

If you enroll WebAuthn (hardware key / passkey) during setup, Forgejo
disables basic auth for the API. You can't use username/password for API
calls. Either use the web UI for everything, or create an API token through
**Settings → Applications → Generate Token** before enrolling WebAuthn.

### 4. Push-to-create is disabled by default

Unlike GitHub, Forgejo doesn't let you push to a non-existent repo and have
it auto-create. You must create repos through the web UI first, then push.

### 5. DO blocks SMTP ports

DigitalOcean blocks outbound TCP on ports 25, 587, and 465. Only port 2525
works. This is a DO thing, not a Forgejo thing. If you're on a different
provider, standard ports should work fine.

## What I learned

- Self-hosting a Git forge is simpler than I expected. The hard part isn't
  the forge — it's the CI/CD runners and email.
- DinD is the right choice for CI isolation, even if it adds a layer of
  complexity with hostname resolution.
- Email on a datacenter IP is a minefield. Use a relay service (Brevo,
  Mailgun, Resend) and port 2525 if your provider blocks the standard ones.
- Push mirroring is the bridge between self-hosted primary and public
  mirror. You don't have to choose one or the other.
- Forgejo's setup wizard doesn't set the SMTP protocol correctly. Always
  verify `PROTOCOL = smtp+starttls` is in the config.

## Next

- Set up pull mirroring from GitHub repos I want to archive locally
- Explore Forgejo's package registry (Container, npm, generic)
- Add more runners for parallel CI jobs
- Terraform module for the full stack (someday, really)
