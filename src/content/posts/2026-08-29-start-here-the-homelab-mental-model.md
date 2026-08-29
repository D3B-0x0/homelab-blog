---
title: "Start here: the homelab mental model"
description: "Before any commands — the 7 concepts that make every self-hosting guide on this blog make sense. Read this first."
date: 2026-08-29
tags: [beginner, concepts, homelab, selfhosting]
---

If you landed here wanting to self-host stuff but the other posts read like
alien hieroglyphs, this is the post for you. No commands. Just the mental
model. Once these click, the rest of the blog is just "put the right software
in the right box."

## 1. A server is just a computer you don't sit in front of

Your laptop runs apps for *you*. A server runs apps for *everyone* (or just
for your devices). It can be a $5/month VPS in the cloud, an old PC under your
desk, or a Raspberry Pi. Same operating system (usually Linux). The only
difference: you reach it over the network, not a keyboard.

## 2. A VPS is a rented server in a datacenter

Companies like DigitalOcean, Hetzner, or Oracle rent you a slice of a machine
in a building far away. You get an IP address and root (admin) access. This is
where most public-facing self-hosted services live, because the machine has a
stable public IP and good internet.

> You don't need a VPS to start. You can self-host on a machine at home. A VPS
> just makes the service reachable from anywhere without fighting your home
> router.

## 3. Docker puts each app in its own box

Imagine every app you run is shipped in a sealed lunchbox with its own fork,
spoon, and napkin. The app can't mess with the others. That "lunchbox" is a
**container**. **Docker** is the tool that builds and runs them. Instead of
"install 15 things and hope they don't conflict," you run 15 containers that
ignore each other. This is why every guide here uses Docker.

## 4. A reverse proxy is the front door

Only one thing can answer on the web's front door (port 443, HTTPS). But you
have 10 services. A **reverse proxy** is the receptionist: "request for
vault.debnerd.in? Send it to the Vaultwarden lunchbox. Request for
searx.debnerd.in? Send it to SearXNG." It also handles HTTPS certificates for
you. (Caddy and Nginx are the common ones.)

## 5. DNS is the phone book of the internet

When you type `blog.debnerd.in`, DNS translates that name into an IP address.
To self-host a service on a nice name, you buy a domain (e.g. `yourname.in`)
and point subdomains at your server's IP. Cloudflare is the popular free DNS
host, and it also sits in front of your server as a protective CDN (that's the
"edge" you'll hear about).

## 6. A VPN mesh joins your devices into one private network

Tailscale (or self-hosted Headscale) makes your laptop, phone, and VPS behave
like they're on the same Wi-Fi — even across the planet — using encrypted
WireGuard tunnels. Nice for reaching home services *without* exposing them to
the public internet. "Tailnet" = your private mesh.

## 7. Security is layers, not a single lock

Self-hosting means *you* are the sysadmin. The posture this blog uses:

- Services sit behind a **reverse proxy** + **CrowdSec** (an intrusion
  prevention system that auto-bans bad traffic).
- Sensitive stuff lives on the **tailnet** only, not the public internet.
- Secrets go in a `.env` file with `chmod 600`, never committed to git.
- Updates happen, backups exist (restic + B2 here), and the firewall drops
  what shouldn't be there.

You don't need all of this on day one. You need: one server, Docker, and a
reverse proxy. Then add layers as you learn.

## The shape of a typical setup

```
            Internet
               │
        Cloudflare (DNS + CDN)
               │
        Reverse proxy (Caddy)  ← terminates HTTPS, routes by name
               │
   ┌───────────┼───────────────┐
Vaultwarden   SearXNG      Headscale (private mesh)
   │
CrowdSec (watches proxy logs, bans attackers)
```

That's it. Every post on this blog is just filling in one of those boxes.

## Where to go next

- **Want to actually build something?** → [Your first VPS: a safe baseline](/posts/2026-08-29-your-first-vps-a-safe-baseline)
- **Want a Git forge of your own?** → Self-hosting Forgejo with CI/CD
- **Want your own private VPN?** → Self-hosting Headscale + Headplane
- **Want to stop getting hacked?** → CrowdSec + Caddy Proxy Manager

## What I learned

The hardest part of self-hosting isn't the software. It's knowing *which box
does which job*. Once you can draw the diagram above from memory, every guide
on the internet becomes readable.
