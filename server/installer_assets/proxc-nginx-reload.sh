#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
