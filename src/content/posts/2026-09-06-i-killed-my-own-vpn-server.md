---
title: "I killed my own VPN server"
description: "I ran my own Tailscale control plane for months. Then I deleted it and went back to SaaS — and that was the right call."
date: 2026-09-06
tags: [tailscale, headscale, vpn, selfhosting, homelab]
---

For months, every device I own — laptop, VPS, phones, the photo server —
joined a private mesh whose control plane lived on my VPS. I ran it myself:
Headscale for coordination, Headplane for the web UI, Google login for auth,
an allowlist of exact emails for who could join. It worked. And then I deleted
the whole thing and moved the network to Tailscale's hosted control plane.

This post is about why deleting working software can be the most senior thing
you do.

## What I built

Quick primer if you're new: Tailscale builds a mesh VPN on WireGuard. Your
devices talk to each other directly, encrypted, with no open ports. The *data*
flows peer to peer — but the *control plane* (who are you, which devices exist,
who may talk to whom) is Tailscale's SaaS by default.

[Headscale](https://github.com/juanfont/headscale) is an open-source
re-implementation of that control plane. [Headplane](https://github.com/tale/headplane)
puts a web UI on top: nodes, users, ACLs, pre-auth keys, expiry. I ran both as
containers on my VPS, behind my reverse proxy, with sign-in restricted to an
exact email allowlist. Full guide in my [Headscale + Headplane](/posts/2026-08-09-self-hosting-headscale-and-headplane)
post.

The motivation was pure principle: *who holds the keys to your network?* My
photos, my servers, my family's devices — I wanted the auth database on my
disk, not in someone else's cloud. Reasonable. Ideological, but reasonable.

## What it cost me

No single outage killed it. It was death by a thousand paper cuts — a little
maintenance every month, always at the worst time:

- **The crash-loop.** The compose stack uses relative paths, so running it from
  a stale copy of the directory made Docker conjure empty root-owned folders
  and both containers crash-looped with "no config file found." Data intact,
  dignity not.
- **Expiry roulette.** Nodes silently fall off the mesh when their keys expire
  — and of course it was always a device I needed *right then*. I disabled
  expiry globally, which traded the annoyance for a real tradeoff: a lost
  device now has no safety net except me remembering to delete it.
- **Key babysitting.** API keys with no permission scopes and hard expiries
  meant calendar-watching a credential that was effectively root over my
  network's brain.
- **Every VPS change touched it.** Migrations, proxy swaps, DNS moves — the
  control plane was coupled to all of them, because everything pointed at it.

None of this was hard. All of it was *mine* — forever. That was the actual
price: not difficulty, but permanence. A background process in my head labeled
"the VPN might need me," running 24/7.

## The decision

The forcing function was moving my whole stack to a new VPS. Re-platforming
day is the one honest moment in infrastructure: you're touching everything
anyway, so you finally ask the question you avoid the rest of the year —
*would I build this again today?*

For the reverse proxy, the forge, the backups: yes. For the VPN control
plane: no.

So the mesh moved to Tailscale's hosted control plane. Same WireGuard crypto,
same tailnet, same private DNS names, same "no open ports" magic. What changed
for every user of the network: absolutely nothing. What changed for me: an
entire category of maintenance evaporated overnight.

## The principle

Self-hosting everything is ideology. Engineering is cost accounting — and
maintenance burden is a real line item, even when the software is free and the
hardware is paid for. Every service you run charges you twice: once in setup,
forever in upkeep. The question is never "can I run this?" (yes, obviously).
It's "is this worth owning?"

A control plane for a family-sized network, guarding photos and SSH sessions,
was not worth owning. Deleting it wasn't surrender — it was the first
infrastructure decision I made like someone responsible for the outcome
instead of someone collecting software.

I didn't lose control of my network. I stopped paying rent on control I never
used.

## What I learned

- The data plane is boring; the control plane is where trust lives. I
  understand that now in my bones, which no tutorial could have given me.
- "Would I build this again today?" is the highest-value question in
  self-hosting. Ask it on every migration, every rebuild, every 2am incident.
- Reversals are underrated. Changing your mind in public, with reasons, reads
  as seniority — because it is.
- Exact email allowlists over wildcard domains, expiry off with manual
  deletion discipline, loopback-only admin APIs. The security habits survived
  even though the server didn't.
