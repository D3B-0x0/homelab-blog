---
title: "Networking 101 for self-hosters"
description: "Networking basics for self-hosters: IPs, ports, public vs private (RFC1918), NAT, DNS, what a reverse proxy is, HTTPS/TLS in plain language."
date: 2026-08-29
tags: [beginner, networking, concepts]
---

If you're new to self-hosting, networking concepts can feel like alphabet soup.
This post breaks down the essentials you need to understand to follow the other
guides on this blog — no jargon without explanation.

## 1. IP addresses: your device's phone number

Every device on a network needs an IP (Internet Protocol) address to send and
receive data. Think of it like a phone number for your computer.

- **IPv4**: `192.168.1.10` — the older format, running out of addresses
- **IPv6**: `2001:db8::1` — the newer format with way more addresses

## 2. Public vs private IPs

Not all IPs are reachable from the internet. This matters for self-hosting:

- **Public IPs**: reachable from anywhere on the internet
  - What you get on a VPS (Virtual Private Server)
  - What your home router gets from your ISP
- **Private IPs**: only work within your local network (RFC1918 ranges)
  - `192.168.x.x` — most common (home/office networks)
  - `10.x.x.x` — larger networks (corporate)
  - `172.16.x.x` to `172.31.x.x` — middle range

Your laptop at home probably has a private IP like `192.168.1.5`. Your VPS has a
public IP like `168.144.74.119`.

## 3. Ports: apartment numbers in a building

If an IP address is a building, ports are apartment numbers. They let multiple
services run on the same IP.

- **Port 22**: SSH (secure shell)
- **Port 80**: HTTP (unencrypted web)
- **Port 443**: HTTPS (encrypted web)
- **Port 25**: SMTP (email)
- **Port 53**: DNS (domain lookups)

Only one service can listen on a specific IP:port combination. That's why you
need a reverse proxy to run multiple web services on port 443.

## 4. NAT: the translator at your network's edge

NAT (Network Address Translation) lets multiple devices share one public IP.

How it works at home:
1. Your laptop (private IP `192.168.1.5`) requests a webpage
2. Your router changes the source IP to your public IP (e.g. `203.0.113.5`)
3. The website responds to your public IP
4. Your router translates back to your laptop's private IP

This is why you need **port forwarding** to self-host at home: you tell your
router "send traffic on port 443 to this specific device."

## 5. DNS: the internet's phone book

DNS (Domain Name System) turns human-readable names like `blog.debnerd.in` into
IP addresses like `168.144.74.119`.

- You type `blog.debnerd.in` in your browser
- Your device asks a DNS server: "what's the IP for this name?"
- The DNS server replies: `168.144.74.119`
- Your device connects to that IP

This is how `blog.debnerd.in` reaches your VPS — even though you never type
the IP address directly.

## 6. Reverse proxy: the front desk for your server

Only one service can listen on port 443 (HTTPS) per IP. But you want to run
multiple websites: `vault.debnerd.in`, `searx.debnerd.in`, `git.debnerd.in`.

A **reverse proxy** solves this:
- Listens on port 443 for all incoming HTTPS traffic
- Looks at the hostname (`vault.debnerd.in` vs `searx.debnerd.in`)
- Forwards the request to the correct backend service
- Also handles HTTPS certificates automatically (with tools like Caddy)

## 7. HTTPS/TLS: sealing the envelope

HTTP sends data in plain text — anyone monitoring the network can read it.
HTTPS adds TLS (Transport Layer Security) encryption:

- Encrypts data between your browser and the server
- Uses certificates to verify you're talking to the real server
- Prevents eavesdropping and tampering

With Caddy and DNS-01 challenges (like I use with Cloudflare), certificate
management is automatic — no certbot or manual renewals needed.

## How these concepts fit together

When you visit `https://vault.debnerd.in`:

1. DNS resolves `vault.debnerd.in` to your VPS's public IP (`168.144.74.119`)
2. Your browser connects to `168.144.74.119:443` and starts TLS handshake
3. Caddy (listening on port 443) decrypts the traffic and sees the hostname
4. Caddy forwards the request to the Vaultwarden container (e.g. `vaultwarden:80`)
5. Vaultwarden responds, Caddy re-encrypts, and sends it back to your browser

## Verify your understanding

- Can you explain why you can't run two websites on the same server:port without a reverse proxy?
- What's the difference between a public IP (VPS) and private IP (home laptop)?
- How does DNS let you use names instead of remembering IP addresses?
- Why does HTTPS matter for self-hosted services?

## Next steps

- [Your first VPS: a safe baseline](/posts/2026-08-29-your-first-vps-a-safe-baseline) — put these concepts into practice
- [Docker 101 for self-hosters](/posts/docker-101) — learn how to package and run apps
- [DNS 101 for self-hosters](/posts/dns-101) — dive deeper into domain management