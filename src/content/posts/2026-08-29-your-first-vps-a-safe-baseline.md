---
title: "Your first VPS: a safe baseline"
description: "A copy-pasteable first hour on a fresh Linux server — non-root user, SSH keys, firewall, and Docker. The floor every other guide here stands on."
date: 2026-08-29
tags: [beginner, vps, linux, security, docker]
---

This is the post I wish existed before I touched my first server. You just
rented a VPS (DigitalOcean/Hetzner/Oracle — anything with Ubuntu or Debian).
You have an IP and a root password. Here's how to make it *not* a botnet
entry in an hour.

> Assumes: a fresh Debian/Ubuntu server, and a terminal on your own machine.
> Commands with a `#` comment are run on the **server**; the one with `$` is
> on **your laptop**.

## Step 0: SSH in as root (once)

```bash
# on your laptop
ssh root@YOUR_SERVER_IP
```

If that works, you're in. Now immediately stop using root for daily work.

## Step 1: make a non-root user

```bash
# on the server
adduser deb          # pick your own username; use a strong password when asked
usermod -aG sudo deb # give it admin (sudo) rights
```

## Step 2: use SSH keys, not passwords

Passwords get brute-forced. Keys don't.

```bash
# on your LAPTOP — if you don't already have a key:
$ ssh-keygen -t ed25519 -C "deb@laptop"
# copy the key to the server (run from your laptop):
$ ssh-copy-id deb@YOUR_SERVER_IP
```

Now try `ssh deb@YOUR_SERVER_IP` — it should log in with no password prompt.

## Step 3: lock the door (harden SSH)

Edit the SSH config and disable root login + password auth:

```bash
# on the server
sudo nano /etc/ssh/sshd_config
```

Set:

```ini
PermitRootLogin no
PasswordAuthentication no
```

Then reload SSH — **keep your current session open** while testing a second
session, so a typo doesn't lock you out:

```bash
sudo systemctl restart ssh
# in a NEW terminal, verify: ssh deb@YOUR_SERVER_IP works and root can't
```

## Step 4: turn on the firewall

Only allow what you actually use (SSH + web). Everything else is dropped.

```bash
# on the server
sudo apt update
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH      # don't lock yourself out!
sudo ufw allow 80,443/tcp  # web traffic (for your future proxy)
sudo ufw enable
sudo ufw status
```

`ufw status` should list SSH and 80,443 as ALLOW. If SSH isn't allowed and you
enable the firewall, you're locked out — that's why we allowed OpenSSH first.

## Step 5: install Docker

This is the box-everything-lives-in from the [mental model](/posts/2026-08-29-start-here-the-homelab-mental-model)
post.

```bash
# on the server
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker deb   # let your user run docker without sudo
```

Log out and back in so the group takes effect, then confirm:

```bash
docker run hello-world
```

If you see "Hello from Docker!", your baseline is done.

## What you have now

- A server where **root can't log in** and **passwords don't work** — only
  your key does.
- A firewall that drops everything except SSH and web.
- Docker ready to run any container from any other guide here.

That's the floor. Everything else on this blog (Forgejo, Headscale, CrowdSec,
SearXNG) is just `docker compose up -d` on top of this.

## Cheat sheet

```bash
ssh deb@YOUR_SERVER_IP          # daily access
sudo ufw status                 # "is my firewall on?"
docker ps                       # "what's running?"
sudo apt upgrade -y             # monthly: install security updates
```

## What I learned

- The single highest-leverage hour on a server is the first one: key-only SSH
  + firewall. Do it before you install *anything*.
- Keep your first SSH session open while you restart sshd. One typo has locked
  out more beginners than any exploit.
- Docker is the great equalizer — once it's installed, every guide speaks the
  same language.

## Next

- Put a reverse proxy in front so you can run many services on one IP →
- Put a reverse proxy + WAF in front so you can run many services on one IP →
  [CrowdSec + plain Caddy](/posts/2026-08-09-crowdsec-and-caddy-proxy-manager)
- Run your own Git forge → Self-hosting Forgejo with CI/CD
