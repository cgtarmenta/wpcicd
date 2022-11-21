FROM ubuntu/nginx:1.18-22.04_edge

LABEL MANTAINER="Tadeo Armenta <contact@tadeoarmenta.com>"

# Let the container know that there is no tty
ENV DEBIAN_FRONTEND noninteractive
# At this point is the only one supported by wordpress echosystem
ENV PHP_VERSION 7.4

# Add php repo
RUN set -x \
    && apt-get update \
    && apt -y install software-properties-common dirmngr apt-transport-https lsb-release ca-certificates \
    && add-apt-repository ppa:ondrej/php
# Install Craft Requirements
RUN set -x \
    && apt-get update \
    && apt-get install -yq --no-install-recommends \
        apt-utils \
        curl \
        iproute2 \
        software-properties-common \
        unzip \
        zip \
    && apt-get update && apt-get install -yq --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-gmp \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-json \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-opcache \
        php${PHP_VERSION}-readline \
        php${PHP_VERSION}-soap \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-redis \
    && echo "#!/bin/sh\nexit 0" > /usr/sbin/policy-rc.d \
    && apt-get autoremove --purge -y \
        software-properties-common \
    && apt-get clean autoclean \
    && apt-get autoremove --yes \
    && rm -rf /var/lib/{apt,dpkg,cache,log}/

# make sure run/php exists and is read/write accesible 
RUN mkdir -p /run/php && chown www-data:www-data /run/php
# make sure there is a log folder and is read/write accesible 
RUN mkdir -p /usr/share/nginx/logs && chown www-data:www-data /usr/share/nginx/logs
RUN mkdir -p /usr/share/nginx/html/shared/nginx_logs && chown www-data:www-data /usr/share/nginx/html/shared/nginx_logs
# make sure there is a user folder and is read/write accesible
RUN mkdir -p /home/ubuntu && chown -R www-data:www-data /home/ubuntu
# remove default files
RUN rm -rf /usr/share/nginx/html/* && rm -rf /etc/nginx/sites-available/*
# PHP config
COPY php /etc/php
# Entrypoints
COPY scripts/php.sh /docker-entrypoint.d/
# COPY scripts/entrypoint.sh /docker-entrypoint.d/
# Nginx config
COPY nginx/default.conf /etc/nginx/sites-available/default
# Update nginx to match worker_processes to # of cpu's
RUN procs=$(cat /proc/cpuinfo |grep processor | wc -l); sed -i -e "s/worker_processes  1/worker_processes $procs/" /etc/nginx/nginx.conf
# Set the actual content
COPY ./site/wordpress /usr/share/nginx/html/release
# Clean wp bloatware
RUN rm -rf /usr/share/nginx/html/release/wp-content

# Link external ones
RUN cd /usr/share/nginx/html/release && ln -s ../shared/wp-content wp-content
RUN cd /usr/share/nginx/html/release && ln -s ../shared/wp-config.php wp-config.php

# Always chown webroot for better mounting
RUN chown -Rf www-data.www-data /usr/share/nginx

# Exports
EXPOSE 80
VOLUME /usr/share/nginx/html/shared
WORKDIR /usr/share/nginx/html/release