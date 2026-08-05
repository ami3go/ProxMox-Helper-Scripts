# Caddy payload

The runtime Caddyfile is generated at `/etc/caddy/Caddyfile`. Existing files are backed up under `/etc/caddy/backups/` before replacement. The helper formats and validates the generated configuration before restarting `caddy.service`.
