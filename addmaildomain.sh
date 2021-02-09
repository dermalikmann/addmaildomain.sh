#!/bin/bash

# Misc

SCRIPTVERSION="1.0"

RED="\033[0;31m"
LRED="\033[1;31m"
GREEN="\033[0;32m"
LGREEN="\033[1;32m"
NOC="\033[0m"
ERR="${LRED}$INDENT> ${RED}"
PROMT="${LGREEN}$INDENT> ${GREEN}"

PATH=$LE_WORKING_DIR:$PATH

log() {
    INDENT=""
    if test $2; then
        INDENT=$(printf "%0.s=" $(seq 1 $2))
    fi
    echo ""
    echo -e "${LGREEN}$INDENT> ${GREEN}$1$NOC"
}

usage() {
    echo ""
    echo -e "${LGREEN}==> ${NOC}Usage:  addmaildomain.sh domain [...]"
    echo ""
    echo -e "${LGREEN}==> ${NOC}An easy way to add new domains to you mail setup"
    echo ""
    echo -e "${LGREEN}==> ${NOC}Config options include currently following environment vars:"
    echo ""
    echo -e "${LGREEN}==> \t${GREEN}\$NGINXCONFDIR$NOC\tPath to the NGINX site config directory${NOC}"
    echo -e "${LGREEN}==> \t\t\t\tUsually /etc/nginx/sites-enabled/"
    echo -e "${LGREEN}==> \t${GREEN}\$ACMECERTDIR$NOC\tPath where the certificate(s) should be installed${NOC}"
    echo -e "${LGREEN}==> \t\t\t\tUsually /etc/acme.sh/"
    echo ""
    echo -e "${LGREEN}==> ${GREEN}https://github.com/dermalikmann/addmaildomain.sh ${RED}Version: $SCRIPTVERSION${NOC}"

}


### Setup ###

if [ $# -eq 0 ]; then
    usage
    exit
fi

case $1 in
  "-h"|"--help"|"help"|"usage")
    usage;
    exit;;
  *);;
esac

if ! command -v acme.sh &> /dev/null; then
    echo -e "${ERR} Could not find acme.sh"
    exit
fi


DOMAINS=$@

NGINXCONFDIR=${NGINXCONFDIR:-"/etc/nginx/sites-enabled"}
ACMECERTDIR=${ACMECERTDIR:-"/etc/acme.sh"}

log "Requesting certificates"

### Certificate ###

for DOMAIN in $DOMAINS; do
    
    log "Creating temporary nginx conf" 2

    NGINXCONFFILE="$NGINXCONFDIR/mail.$DOMAIN"

    if test -f $NGINXCONFFILE; then
        mv $NGINXCONFFILE $NGINXCONFFILE.bak
    fi

    touch $NGINXCONFFILE

    cat  << EOT >> $NGINXCONFFILE
server {
listen 80;
listen [::]:80;
server_name mail.$DOMAIN smtp.$DOMAIN imap.$DOMAIN;

add_header Strict-Transport-Security max-age=86000;
}
EOT



    log "Reloading NGINX" 2
    systemctl reload nginx.service


    log "Requesting certificate for {mail,imap,smtp}.$DOMAIN" 2
    acme.sh --issue --nginx -d mail.$DOMAIN -d imap.$DOMAIN -d smtp.$DOMAIN


    log "Restoring to previous NGINX state" 2

    NGINXCONFFILE="$NGINXCONFDIR/mail.$DOMAIN"
    rm -rf $NGINXCONFFILE

    if test -f $NGINXCONFFILE.bak; then
        mv $NGINXCONFFILE.bak $NGINXCONFFILE
    fi
done

systemctl reload nginx.service



log "Installing certifcate in $ACMECERTDIR"

for DOMAIN in $DOMAINS; do

    mkdir -p "$ACMECERTDIR/mail.$DOMAIN"
    acme.sh --install-cert -d mail.$DOMAIN --key-file "$ACMECERTDIR/mail.$DOMAIN/privkey.pem" --fullchain-file "$ACMECERTDIR/mail.$DOMAIN/fullchain.pem"

done


### Configure Postfix & Dovecot


log "Configuring Postfix"

log "Creating postfix SNI map" 2

for DOMAIN in $DOMAINS; do

    cat << EOT | tee -a /etc/postfix/sni_ssl_certs

# $DOMAIN

mail.$DOMAIN /etc/acme.sh/mail.$DOMAIN/privkey.pem /etc/acme.sh/mail.$DOMAIN/fullchain.pem
imap.$DOMAIN /etc/acme.sh/mail.$DOMAIN/privkey.pem /etc/acme.sh/mail.$DOMAIN/fullchain.pem
smtp.$DOMAIN /etc/acme.sh/mail.$DOMAIN/privkey.pem /etc/acme.sh/mail.$DOMAIN/fullchain.pem
EOT

done


log "Generating hash map" 2

postmap -f hash:/etc/postfix/sni_ssl_certs


log "Creating dovecot SNI config"

for DOMAIN in $DOMAINS; do

    cat << EOT | tee -a /etc/dovecot/sni_ssl_certs.conf

local_name mail.$DOMAIN {
  ssl_cert = </etc/acme.sh/mail.$DOMAIN/fullchain.pem
  ssl_key = </etc/acme.sh/mail.$DOMAIN/privkey.pem
}

local_name imap.$DOMAIN {
  ssl_cert = </etc/acme.sh/mail.$DOMAIN/fullchain.pem
  ssl_key = </etc/acme.sh/mail.$DOMAIN/privkey.pem
}

local_name smtp.$DOMAIN {
  ssl_cert = </etc/acme.sh/mail.$DOMAIN/fullchain.pem
  ssl_key = </etc/acme.sh/mail.$DOMAIN/privkey.pem
}

EOT

done

log "Reloading services"

systemctl reload postfix dovecot nginx

log "Done :)"