server {
    listen 80;
    server_name __SERVER_ADDRESS__ *.__SERVER_ADDRESS__;

    location /.well-known/acme-challenge/ {
        root __ACME_WEBROOT__;
    }

    location = /_proxc/register {
        proxy_pass http://127.0.0.1:__REGISTER_PORT__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /_proxc/admin {
        return 301 https://$host$request_uri;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name __SERVER_ADDRESS__;

    ssl_certificate /etc/letsencrypt/live/__SERVER_ADDRESS__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__SERVER_ADDRESS__/privkey.pem;

    location = /_proxc/register {
        proxy_pass http://127.0.0.1:__REGISTER_PORT__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /_proxc/admin {
        proxy_pass http://127.0.0.1:__REGISTER_PORT__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /_proxc_mirror {
        internal;
        proxy_pass http://127.0.0.1:__REGISTER_PORT__/_proxc/internal/mirror;
        proxy_set_header X-Proxc-Mirror-Secret "__MIRROR_SHARED_SECRET__";
        proxy_set_header X-Proxc-Original-Host $host;
        proxy_set_header X-Proxc-Original-Uri $request_uri;
        proxy_set_header X-Proxc-Method $request_method;
        proxy_set_header X-Proxc-Remote-Addr $remote_addr;
        proxy_set_header X-Proxc-Scheme $scheme;
    }

    location / {
        mirror /_proxc_mirror;
        mirror_request_body on;
        proxy_pass http://localhost:7080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
