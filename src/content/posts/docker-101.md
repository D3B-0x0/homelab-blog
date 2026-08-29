---
title: "Docker 101 for self-hosters"
description: "Docker for self-hosters: what a container/image is, docker compose, volumes, networks, why we use it. Include a tiny copy-paste 'run your first container' example (nginx hello-world)."
date: 2026-08-29
tags: [beginner, docker, concepts]
---

If you've heard "just run it in Docker" but aren't sure what that means, this
post is for you. We'll cover the core concepts you need to understand every
self-hosting guide on this blog — with a hands-on example you can try right now.

## 1. Images vs containers: recipe vs meal

Think of Docker like cooking:

- **Image**: the recipe and ingredients (read-only template)
- **Container**: the actual cooked meal running from that recipe (isolated process)

You download an image once, then run many containers from it. Images are stored
locally or in registries like Docker Hub.

## 2. Why Docker solves the "dependency hell" problem

Before Docker: installing an app meant hoping its dependencies didn't conflict
with what you already had. "Install PHP 7.4" might break your PHP 8.0 app.

With Docker: each app gets its own isolated filesystem with exactly the
dependencies it needs. No more "it works on my machine" — if it runs in the
container, it'll run anywhere Docker runs.

## 3. Key concepts you'll see everywhere

### Volumes: persistent storage

Containers are ephemeral — delete the container, and its internal changes are
gone. Volumes let you persist data:

- Database files (PostgreSQL, MySQL)
- Config files you edit
- Uploaded media (photos, documents)

In compose: `volumes: ./mydata:/data` mounts host folder `./mydata` into
container path `/data`.

### Networks: how containers talk

By default, containers can talk to each other on a Docker network. You create
private networks so only specific containers can communicate:

- `edge-net`: my public-facing network (Caddy ↔ backend services)
- Internal networks: for databases that shouldn't be reached directly

### Ports: exposing containers to the world

`-p 8080:80` means "map container port 80 to host port 8080."  
Without this, the container's service is only reachable by other containers on
the same network.

### docker compose: defining your stack

Instead of long `docker run` commands, docker-compose.yml defines your entire
stack in one file. `docker compose up -d` starts everything; `docker compose
down` stops it.

## 4. Your first container: copy-paste this

Let's run nginx (a web server) and see it work:

```bash
# Pull the nginx image and run it
docker run -d \
  --name hello-nginx \
  -p 8080:80 \
  nginx:alpine

# Open in your browser: http://localhost:8080
# You should see the nginx welcome page

# See it running
docker ps

# Stop and remove it when done
docker stop hello-nginx
docker rm hello-nginx
```

What happened:
1. Docker downloaded the `nginx:alpine` image (if not already cached)
2. Created a container named `hello-nginx` from that image
3. Mapped container port 80 to your machine's port 8080
4. Started nginx in the background (`-d`)
5. You visited `localhost:8080` and saw the web server respond

## 5. How self-hosting uses Docker

Every service in my homelab runs in its own container:

- `caddy`: reverse proxy (ports 80/443 mapped to host)
- `searxng-core`: search engine (only reachable by Caddy on edge-net)
- `vaultwarden`: password manager (only reachable by Caddy)
- `forgejo`: Git forge (SSH port 2222 mapped, web via Caddy)
- `headscale`: VPN control plane (only reachable by Caddy)
- `postgres`: databases (only reachable by their apps on shared networks)

Each container:
- Has exactly what it needs (no extra shells or tools)
- Can't interfere with other containers
- Can be updated/restarted independently
- Shares networks only with intended services

## 6. Data persistence: where your stuff lives

That nginx test was ephemeral — delete the container, and it's gone. For real
services, you need volumes:

```yaml
# Example from my Vaultwarden setup
services:
  vaultwarden:
    image: vaultwarden/server:latest
    volumes:
      - ./vw-data:/data  # ← This persists your passwords, attachments, etc.
```

Without that volume, restarting the container would lose all your data.

## 7. Verifying your Docker setup

```bash
# Is Docker running?
docker info

# What images do you have locally?
docker images

# What containers are running?
docker ps

# What containers exist (including stopped)?
docker ps -a

# See logs from a container
docker logs hello-nginx

# Enter a running container (for debugging)
docker exec -it hello-nginx sh
```

## How this fits into self-hosting

When you see `docker compose up -d` in a guide:
1. It reads the compose.yml file
2. Pulls any needed images
3. Creates containers with specified volumes/networks/ports
4. Starts them in the background
5. Sets up restart policies so they survive reboots

## Next steps

- [Networking 101 for self-hosters](/posts/networking-101) — understand how containers talk
- [DNS 101 for self-hosters](/posts/dns-101) — learn how names reach your services
- [Your first VPS: a safe baseline](/posts/2026-08-29-your-first-vps-a-safe-baseline) — get a server to practice on