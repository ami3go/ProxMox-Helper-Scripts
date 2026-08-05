services:
  homepage:
    image: {{HOMEPAGE_IMAGE}}
    container_name: homepage
    restart: unless-stopped
    ports:
      - "127.0.0.1:{{HOMEPAGE_PORT}}:3000"
    volumes:
      - /opt/homepage/config:/app/config
      - /etc/localtime:/etc/localtime:ro
      - /srv/workspace:/srv/workspace:ro
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "{{DASHBOARD_FQDN}}"
