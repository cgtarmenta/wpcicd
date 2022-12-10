FROM php:8.1-fpm-alpine

LABEL MANTAINER="Tadeo Armenta <contact@tadeoarmenta.com>"

# persistent dependencies
RUN set -eux; \
	apk add --no-cache \
# in theory, docker-entrypoint.sh is POSIX-compliant, but priority is a working, consistent image
		bash \
# Ghostscript is required for rendering PDF previews
		ghostscript \
# Alpine package for "imagemagick" contains ~120 .so files, see: https://github.com/docker-library/wordpress/pull/497
		imagemagick \
	;

# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN set -ex; \
	\
	apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		freetype-dev \
		icu-dev \
		imagemagick-dev \
		libjpeg-turbo-dev \
		libpng-dev \
		libwebp-dev \
		libzip-dev \
	; \
	\
	docker-php-ext-configure gd \
		--with-freetype \
		--with-jpeg \
		--with-webp \
	; \
	docker-php-ext-install -j "$(nproc)" \
		bcmath \
		exif \
		gd \
		intl \
		mysqli \
		zip \
	; \
# WARNING: imagick is likely not supported on Alpine: https://github.com/Imagick/imagick/issues/328
# https://pecl.php.net/package/imagick
	pecl install imagick-3.6.0; \
	docker-php-ext-enable imagick; \
	rm -r /tmp/pear; \
	\
# some misbehaving extensions end up outputting to stdout 🙈 (https://github.com/docker-library/wordpress/issues/669#issuecomment-993945967)
	out="$(php -r 'exit(0);')"; \
	[ -z "$out" ]; \
	err="$(php -r 'exit(0);' 3>&1 1>&2 2>&3)"; \
	[ -z "$err" ]; \
	\
	extDir="$(php -r 'echo ini_get("extension_dir");')"; \
	[ -d "$extDir" ]; \
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive "$extDir" \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-network --virtual .wordpress-phpexts-rundeps $runDeps; \
	apk del --no-network .build-deps; \
	\
	! { ldd "$extDir"/*.so | grep 'not found'; }; \
# check for output like "PHP Warning:  PHP Startup: Unable to load dynamic library 'foo' (tried: ...)
	err="$(php --version 3>&1 1>&2 2>&3)"; \
	[ -z "$err" ]
# Install nginx
RUN apk add --no-cache nginx
# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
	docker-php-ext-enable opcache; \
	{ \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

# # PHP config
RUN mkdir -p /run/php && chown www-data:www-data /run/php
COPY php/www.conf /usr/local/etc/php-fpm.d/www.conf

# # make sure there is a log folder and is read/write accesible 
RUN mkdir -p /usr/share/nginx/logs && chown www-data:www-data /usr/share/nginx/logs
RUN mkdir -p /usr/share/nginx/html/shared/nginx_logs && chown www-data:www-data /usr/share/nginx/html/shared/nginx_logs
# # make sure there is a user folder and is read/write accesible
RUN mkdir -p /home/ubuntu && chown -R www-data:www-data /home/ubuntu

# # Nginx config
# RUN mkdir -p /etc/nginx/{'modules-enabled','conf.d','sites-enabled'}
# COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/default.conf /etc/nginx/http.d/default.conf
# # Update nginx to match worker_processes to # of cpu's
RUN procs=$(cat /proc/cpuinfo |grep processor | wc -l); sed -i -e "s/worker_processes  1/worker_processes $procs/" /etc/nginx/nginx.conf
# # Set the actual content
COPY ./site/wordpress /usr/share/nginx/html/release
# # Clean wp bloatware
RUN rm -rf /usr/share/nginx/html/release/wp-content

# Link external ones
RUN cd /usr/share/nginx/html/release && ln -s ../shared/wp-content wp-content
RUN cd /usr/share/nginx/html/release && ln -s ../shared/wp-config.php wp-config.php

# Always chown webroot for better mounting
RUN chown -Rf www-data.www-data /usr/share/nginx
# work entrypoints
COPY scripts/entrypoint.sh /docker-entrypoint.sh
RUN mkdir -p /docker-entrypoint.d
COPY scripts/30-tune-worker-processes.sh /docker-entrypoint.d
# # Exports
EXPOSE 80
VOLUME /usr/share/nginx/html/shared
WORKDIR /usr/share/nginx/html/release

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["/bin/bash", "-c", "php-fpm & nginx -g 'daemon off;'"]