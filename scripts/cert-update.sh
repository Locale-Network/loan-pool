#!/bin/bash

DOMAIN=$1
EMAIL=$2

cd $HOME/loan-pool
docker compose run --rm certbot-renew certonly --non-interactive --webroot -w /var/www/certbot --agree-tos --email $EMAIL -d $DOMAIN

docker compose restart server