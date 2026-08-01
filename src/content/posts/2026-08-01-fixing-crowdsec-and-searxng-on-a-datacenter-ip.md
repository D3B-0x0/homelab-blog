---
title: "Fixing CrowdSec and SearXNG on a datacenter IP"
date: 2026-08-01
tags: [crowdsec, searxng, selfhosting]
---

## What I worked on

The VPS had a bad day after a full stack down/up, and fixing it taught me a
lot about how the CrowdSec WAF and SearXNG actually work under the hood.

### The CrowdSec WAF "wasn't blocking"

After restarting every container, exploit probes were sailing through
(`/util/php/eval-stdin.php` returned 404 from the app instead of a 403 block)
and the AppSec engine counter was barely moving. The logs showed:

```
level=error msg="Unauthorized request from '172.18.0.4:45086' (real IP = ): missing API key" module=acquisition.appsec
```

My first instinct was to blame the Traefik bouncer plugin not sending the
right key. I pulled the plugin source and traced how it populates the
`X-Crowdsec-Appsec-Api-Key` header.

**The red herring:** the `missing API key` error was from *my own diagnostic
`wget`* to the AppSec listener on `crowdsec:7422` — a headerless request. Real
traffic was fine. The WAF had been working all along; my probes were just too
early (bouncer decision cache is 15s, AppSec auth cache ~1min).

Lesson: when debugging, make sure the log line you're chasing is actually
caused by the traffic you think it is.

### Probing your own WAF bans your own IP

Once the WAF *was* verified working (403 on the probe), every normal request
from the VPS started returning 403 too. Checking `cscli decisions list`
showed why:

```
| 441397 | crowdsec | Ip:2400:6180:100:d0:0:1:6d24:e001 | crowdsecurity/CVE-2017-9841 | ban |
```

Probing the WAF **from the VPS host** made CrowdSec ban the VPS's *own IPv6*.
That's the vpatch rule doing exactly its job. Cleanup:

```bash
cscli decisions delete --id 441397
```

Two gotchas here:
- `-i` parses the argument as an IP, not an ID. Use `--id <n>` to delete by ID.
- The bouncer caches decisions for ~15s, so the 403s don't stop instantly.
  Wait ~16s after deleting before retesting.

### http-probing was flagging my own ISP

My home IP (Alliance Broadband, dynamic) kept getting captcha'd by the
`http-probing` scenario. Whitelisting a dynamic IP is pointless, so I overrode
the scenario with a local file instead of the hub symlink:

```yaml
# /etc/crowdsec/scenarios/http-probing.yaml (local override)
capacity: 25    # was 10
leakspeed: "30s"  # was 10s
```

A scanner will still trip it; normal browsing won't.

## SearXNG and the datacenter IP problem

Every search returned nothing. Root cause: the VPS's datacenter IP is
rate-limited / captcha'd by **Google, DuckDuckGo, Brave, and Startpage** — the
engines `use_default_settings: true` enables. DDG captchas on *every* request:

```
ERROR:searx.engines.duckduckgo: CAPTCHA (wt-wt)
ERROR:searx.engines.startpage: got redirected to .../sp/captcha (suspended_time=3600)
```

Fix in `/home/ghostvps/searxng/core-config/settings.yml`:

```yaml
engines:
  - name: google
    disabled: true
  - name: duckduckgo
    disabled: true
  - name: brave
    disabled: true
  - name: startpage
    disabled: true
  # bing + mojeek tolerate the datacenter IP
```

Autocomplete was also pinned to duckduckgo (same problem) — switched to
`qwant`, which ignores datacenter IPs entirely.

**The ceiling:** from a datacenter IP, Bing is effectively the only engine
that reliably returns results. Getting Google/DDG back means routing through a
residential IP (e.g. a SOCKS proxy on my laptop over Tailscale) — that's a
future project.

## What I learned

- Log lines can lie — verify which traffic actually triggered them.
- CrowdSec's AppSec is in-band (sits in front of apps); LAPI is out-of-band.
- Datacenter IPs are treated as bots by search engines. It's not about
  privacy, it's about their ad business and scraper defense.
- `cscli decisions delete --id <n>` ≠ `-i <n>`.

## Next

- Set up the laptop-as-SOCKS-proxy hack so Google/DDG work through my
  residential IP.
- Document the whole Pangolin/CrowdSec build in this blog.
