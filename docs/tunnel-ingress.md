# Cloudflare Tunnel ingress (`--ingress tunnel`)

Use this mode when the host has **no reachable public inbound** — a home server, a
box behind NAT/CGNAT, or anywhere you can't (or won't) forward ports `80`/`443`.
Instead of Traefik answering inbound HTTP-01 challenges for Let's Encrypt, a
[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
dials **outbound** to Cloudflare's edge; Cloudflare terminates TLS for free and
forwards requests down the tunnel to Traefik.

```bash
sudo ./install.sh --domain yourdomain.com --ingress tunnel
```

## What you need first

1. **The domain on Cloudflare.** The zone's nameservers must point at Cloudflare
   (free plan is fine). The installer creates DNS records via the API.
2. **A Cloudflare API token** — create at
   <https://dash.cloudflare.com/profile/api-tokens> with these scopes:
   - `Account` → `Cloudflare Tunnel` → `Edit`
   - `Zone` → `DNS` → `Edit`
   - `Zone` → `Zone` → `Read`
3. **Your Cloudflare account id** (Dashboard → any domain → Overview → API section).

Put both in `answers.env`:

```env
DOMAIN=yourdomain.com
CLOUDFLARE_API_TOKEN=<token>
CLOUDFLARE_ACCOUNT_ID=<account-id>
# optional:
# CLOUDFLARE_TUNNEL_NAME=devhub
# DOKPLOY_GATE_USER=admin
# DOKPLOY_GATE_PASSWORD=<gate password>
```

`install.sh` also accepts these as environment variables or via the flag
`--ingress tunnel`. It fails fast with a clear message if the token or account id
is missing.

## ⚠️ Domain depth and the free certificate

Cloudflare's **free Universal SSL** covers only the zone apex and a **single**
wildcard level:

```
yourdomain.com          ✅ covered
*.yourdomain.com        ✅ covered   →  app.yourdomain.com works
*.ai.yourdomain.com     ❌ NOT covered →  app.ai.yourdomain.com fails the TLS handshake
```

So pass the **zone apex** as `--domain` (apps land at `<app>.yourdomain.com`). If
you pass a subdomain, the installer detects it — it looks up the parent zone via
the API and **warns** that apps will be two levels deep and the free cert won't
reach them, naming the zone you should use instead. To deploy deeper anyway,
enable [Advanced Certificate Manager / Total TLS](https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/)
on the zone first.

## What the installer does (topology)

[`automation/setup_tunnel.py`](../automation/setup_tunnel.py), run from step 7 of
`install.sh` in tunnel mode:

1. **Installs `cloudflared`** — downloads the official `.deb` for the host arch
   (`amd64`/`arm64`) if not already present.
2. **Creates (or reuses) a named tunnel** via the Cloudflare API. The tunnel
   secret is generated locally and written to
   `/etc/cloudflared/<uuid>.json` (mode `0600`). An existing tunnel of the same
   name is reused when its local credentials file survives; otherwise it is
   recreated so the secret can be re-obtained.
3. **Writes `/etc/cloudflared/config.yml`** — a single wildcard ingress rule plus
   a `404` catch-all:

   ```yaml
   tunnel: <uuid>
   credentials-file: /etc/cloudflared/<uuid>.json
   ingress:
     - hostname: "*.yourdomain.com"
       service: http://localhost:80
     - service: http_status:404
   ```

4. **Upserts a proxied wildcard `CNAME`** `*.yourdomain.com` →
   `<uuid>.cfargotunnel.com` (one record covers every current and future app).
5. **Installs the `cloudflared` systemd service** (`systemctl enable --now
   cloudflared`), running from the local config above.

Then `install.sh` applies two Traefik dynamic-config tweaks (tunnel mode only):

- **Redirect neutralization** (`/etc/dokploy/traefik/dynamic/tunnel-ingress.yml`) —
  the tunnel forwards **plain HTTP** to Traefik on loopback `:80` (edge + tunnel
  are already encrypted), so Traefik's default `:80`→`:443` redirect would loop
  every app. The `redirect-to-https` middleware is redefined as a benign no-op
  headers middleware.
- **Dokploy access gate** (`/etc/dokploy/traefik/dynamic/dokploy-auth.yml`) —
  publishes the dashboard at `https://dokploy.yourdomain.com` behind Traefik
  basic-auth (`entryPoints: [web, websecure]`, **no** `tls:` key so it matches the
  tunnel's plain `:80` hop). Credentials default to `admin` / the Dokploy admin
  password.

## Why plain HTTP on the loopback hop

The obvious alternative — pointing the tunnel at Traefik's `:443` — needs
`cloudflared`'s `noTLSVerify` (Traefik serves a default self-signed cert on
loopback until a real cert exists). Forwarding to `:80` avoids disabling TLS
verification entirely while keeping the link encrypted end to end: browser → **CF
edge (TLS)** → **tunnel (encrypted)** → `cloudflared` → `localhost:80` (on-host
loopback only).

## Verifying

```bash
# tunnel service up?
systemctl status cloudflared

# tunnel registered + connectors healthy?
cloudflared tunnel info <tunnel-name>

# an app answers through Traefik on the loopback hop (expect 200/3xx, not a redirect loop):
curl -sI -H "Host: hub.yourdomain.com" http://localhost:80/

# the Dokploy gate (expect 401 without creds, 200/302 with):
curl -sI -H "Host: dokploy.yourdomain.com" http://localhost:80/
curl -sI -u admin:<password> -H "Host: dokploy.yourdomain.com" http://localhost:80/

# end to end from outside:
curl -sI https://hub.yourdomain.com
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| TLS handshake fails only on `<app>.<sub>.<domain>` | Domain is two levels deep; free Universal SSL doesn't cover it. Use the zone apex as `--domain`, or enable ACM/Total TLS. |
| Apps return a redirect loop / `ERR_TOO_MANY_REDIRECTS` | Redirect neutralization didn't apply. Confirm `tunnel-ingress.yml` exists and `docker restart dokploy-traefik` ran. |
| `dokploy.<domain>` returns `404` | The gate router must have **no** `tls:` key (that makes it websecure-only and the tunnel's `:80` hop misses it). Check `dokploy-auth.yml`. |
| `cloudflared` won't start | Check `/etc/cloudflared/config.yml` and the `<uuid>.json` credentials file exist and match; `journalctl -u cloudflared -e`. |
| API error on setup | The token is missing a scope — needs Account>Cloudflare Tunnel>Edit, Zone>DNS>Edit, Zone>Zone>Read. The exact Cloudflare error is printed. |
| Re-run created a second tunnel | It shouldn't — reuse is keyed on tunnel name + the local credentials file. If the creds file was deleted, the tunnel is recreated by design (the API won't re-reveal a secret). |
