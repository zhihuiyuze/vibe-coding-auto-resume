# site/

Static landing page for `vibe-resume.huize.org`. No build step.

Layout:

```
site/
├── index.html        # English landing (canonical, /)
├── zh/index.html     # 中文 (/zh/)
├── fr/index.html     # Français (/fr/)
├── ru/index.html     # Русский (/ru/)
├── 404.html          # served for any 404 — uses /style.css (absolute)
├── style.css         # shared stylesheet, dark-mode-aware
├── sitemap.xml       # hreflang-annotated, all 4 language URLs
└── robots.txt        # allow-all + sitemap reference
```

Each language page carries `<link rel="alternate" hreflang>` references to
all four locales plus `x-default`, Open Graph + Twitter Card meta, and a
JSON-LD `SoftwareApplication` schema.

This directory is named `site/` (project marketing / docs landing) so the
short `web/`, `app/`, `webapp/`, `frontend/`, `dashboard/`, `ui/` names stay
free for a future web product built on top of vibe.

## Deploy

Plain `rsync` to your static host:

```bash
rsync -avz --delete site/ user@host:/var/www/vibe-resume/
```

Example nginx / OpenResty server block:

```nginx
server {
    listen 443 ssl http2;
    server_name vibe-resume.huize.org;

    root /var/www/vibe-resume;
    index index.html;

    error_page 404 /404.html;

    location / {
        try_files $uri $uri/ =404;
    }

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

The `try_files $uri $uri/` pattern resolves `/zh/` to `/zh/index.html`
automatically. The `error_page 404 /404.html` line makes the styled 404
page replace nginx's default for any unmatched URL.

Caddy equivalent (auto-HTTPS, same try_files semantics):

```caddy
vibe-resume.huize.org {
    root * /var/www/vibe-resume
    file_server
    encode zstd gzip
    handle_errors {
        @404 expression {http.error.status_code} == 404
        rewrite @404 /404.html
        file_server
    }
}
```

## Edit before publishing

The English page already has the source link pinned to
`github.com/zhihuiyuze/vibe-coding-auto-resume`. If you fork, search/replace
`zhihuiyuze` with your GitHub username/org in `index.html`, `zh/index.html`,
`fr/index.html`, `ru/index.html`, and `sitemap.xml`.

```bash
grep -rln zhihuiyuze site/ | xargs sed -i 's|zhihuiyuze|your-gh-username|g'
```

## Local preview

```bash
cd site && python3 -m http.server 8080
# open http://localhost:8080
# also try http://localhost:8080/zh/  /fr/  /ru/  /nonexistent (404)
```

Edit HTML/CSS, refresh.

## SEO checklist (what each page has)

- `<html lang>` set to page locale
- `<title>` + `<meta description>` in the page's language
- `<link rel="canonical">` self-pointing
- `<link rel="alternate" hreflang>` × 5 (en, zh, fr, ru, x-default)
- Open Graph: `og:type`, `og:title`, `og:description`, `og:url`,
  `og:locale`, `og:locale:alternate` × 3
- Twitter Card: `summary`
- JSON-LD `SoftwareApplication` schema with `inLanguage` array
- `<meta name="theme-color">` for both light + dark
- Top-and-bottom language switcher

`sitemap.xml` lists all four URLs with `xhtml:link` hreflang per URL —
the form Google's docs recommend for international sites.
