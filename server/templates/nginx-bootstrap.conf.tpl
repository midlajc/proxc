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

    location / {
        proxy_pass http://localhost:7080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
