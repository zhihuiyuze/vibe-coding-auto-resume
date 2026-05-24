# site/

Static landing page for `vibe-resume.huize.org`. Two files of real content, no build step.

- `index.html` — single-page landing.
- `style.css` — minimal terminal-flavored stylesheet, dark mode aware via `prefers-color-scheme`.

This directory is named `site/` (project marketing / docs landing) so the
short `web/`, `app/`, `webapp/`, `frontend/`, `dashboard/`, `ui/` names stay
free for a future web product built on top of vibe.

## Deploy

Plain `rsync` to your static host:

```bash
rsync -avz --delete site/ user@host:/var/www/vibe-resume/
```

Example nginx server block (TLS via your existing cert chain):

```nginx
server {
    listen 443 ssl http2;
    server_name vibe-resume.huize.org;

    root /var/www/vibe-resume;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # cache static assets
    location ~* \.(css|js|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}

server {
    listen 80;
    server_name vibe-resume.huize.org;
    return 301 https://$host$request_uri;
}
```

Caddy equivalent (auto-HTTPS):

```caddy
vibe-resume.huize.org {
    root * /var/www/vibe-resume
    file_server
    encode zstd gzip
}
```

## Edit before publishing

Search/replace `REPLACE_ME` in `index.html` with your GitHub username/org so
the "Source" link and footer point to the right repo.

```bash
sed -i 's|REPLACE_ME|your-gh-username|g' site/index.html
```

## Local preview

```bash
cd site && python3 -m http.server 8080
# open http://localhost:8080
```

Edit HTML/CSS, refresh.
