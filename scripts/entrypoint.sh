#!/bin/bash

set -euo pipefail

MOUNTPOINT=/usr/share/nginx/html

for dir in shared release; do
    if [[ ! -d $MOUNTPOINT/$dir && -d /wordpress/$dir ]]; then
        ln -s /wordpress/$dir $MOUNTPOINT/$dir && echo "Linked $MOUNTPOINT/$dir to /wordpress/$dir."
    fi
done

file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi
  local val="$def"
  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(< "${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}

[ -d $MOUNTPOINT/release ] || mkdir $MOUNTPOINT/release

cd $MOUNTPOINT/release

  # allow any of these "Authentication Unique Keys and Salts" to be specified
  # via environment variables with a `WORDPRESS_` prefix
  # (e.g. `WORDPRESS_AUTH_KEY` for `AUTH_KEY`)
  uniqueEnvs=(
    AUTH_KEY
    SECURE_AUTH_KEY
    LOGGED_IN_KEY
    NONCE_KEY
    AUTH_SALT
    SECURE_AUTH_SALT
    LOGGED_IN_SALT
    NONCE_SALT
  )

  envs=(
    WORDPRESS_DB_HOST
    WORDPRESS_DB_USER
    WORDPRESS_DB_PASSWORD
    WORDPRESS_DB_NAME
    "${uniqueEnvs[@]/#/WORDPRESS_}"
    WORDPRESS_TABLE_PREFIX
    WORDPRESS_DEBUG
    WORDPRESS_URL
  )

  haveConfig=

  for e in "${envs[@]}"; do
    file_env "$e"
    if [ -z "$haveConfig" ] && [ -n "${!e}" ]; then
      haveConfig=1
    fi
  done

  # linking backwards-compatibility
  if [ -n "${!MYSQL_ENV_MYSQL_*}" ]; then
    haveConfig=1
    # host defaults to "mysql" below if unspecified
    : "${WORDPRESS_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}"
    if [ "$WORDPRESS_DB_USER" = 'root' ]; then
      : "${WORDPRESS_DB_PASSWORD:=${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
    else
      : "${WORDPRESS_DB_PASSWORD:=${MYSQL_ENV_MYSQL_PASSWORD:-}}"
    fi
    : "${WORDPRESS_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-}}"
  fi

  # only touch "wp-config.php" if we have environment-supplied configuration values
  if [ "$haveConfig" ]; then
    : "${WORDPRESS_DB_HOST:=mysql}"
    : "${WORDPRESS_DB_USER:=root}"
    : "${WORDPRESS_DB_PASSWORD:=}"
    : "${WORDPRESS_DB_NAME:=wordpress}"

    # version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
    # https://github.com/docker-library/wordpress/issues/116
    # https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4
    sed -ri -e 's/\r$//' wordpress/wp-config*

if [ ! -e $MOUNTPOINT/shared/wp-config.php ]; then
      awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wordpress/wp-config-sample.php > $MOUNTPOINT/shared/wp-config.php << 'EOPHP'
    // If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
    // see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
    if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
    }

    define('WP_HOME', 'unset');
    define('WP_SITEURL', 'unset');
    define('WP_CONTENT_DIR', '/var/www/html/shared/wp-content/');
    define('WP_CONTENT_URL', 'unset');
    define('WP_PLUGIN_URL', 'unset');
    define('FS_METHOD', 'direct');

    # Leave this set to false. We're in a container, so we will
    # never be able to update from inside of Wordpress
    define( 'WP_AUTO_UPDATE_CORE', false );

    # Disable file editing
    define('DISALLOW_FILE_EDIT', true);

EOPHP
    chown www-data:www-data $MOUNTPOINT/shared/wp-config.php
    chmod 640 $MOUNTPOINT/shared/wp-config.php
fi

    # see http://stackoverflow.com/a/2705678/433558
    sed_escape_lhs() {
      echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
    }

    sed_escape_rhs() {
      echo "$@" | sed -e 's/[\/&]/\\&/g'
    }

    php_escape() {
      local escaped="$(php -r 'var_export(('"$2"') $argv[1]);' -- "$1")"
      if [ "$2" = 'string' ] && [ "${escaped:0:1}" = "'" ]; then
        escaped="${escaped//$'\n'/"' + \"\\n\" + '"}"
      fi
      echo "$escaped"
    }

    set_config() {
      key="$1"
      value="$2"
      var_type="${3:-string}"
      start="(['\"])$(sed_escape_lhs "$key")\2\s*,"
      end="\);"
      if [ "${key:0:1}" = '$' ]; then
        start="^(\s*)$(sed_escape_lhs "$key")\s*="
        end=";"
      fi
      sed -ri -e "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" $MOUNTPOINT/shared/wp-config.php
    }

    set_config 'DB_HOST' "$WORDPRESS_DB_HOST"
    set_config 'DB_USER' "$WORDPRESS_DB_USER"
    set_config 'DB_PASSWORD' "$WORDPRESS_DB_PASSWORD"
    set_config 'DB_NAME' "$WORDPRESS_DB_NAME"
    set_config 'WP_HOME' "$WORDPRESS_URL"
    set_config 'WP_SITEURL' "$WORDPRESS_URL/wordpress"
    set_config 'WP_CONTENT_URL' "${WORDPRESS_URL}/wp-content"
    set_config 'WP_PLUGIN_URL' "${WORDPRESS_URL}/wp-content/plugins"

    for unique in "${uniqueEnvs[@]}"; do
      uniqVar="WORDPRESS_$unique"
      if [ -n "${!uniqVar}" ]; then
        set_config "$unique" "${!uniqVar}"
      else
        # if not specified, let's generate a random value
        currentVal="$(sed -rn -e "s/define\(\s*((['\"])$unique\2\s*,\s*)(['\"])(.*)\3\s*\);/\4/p" $MOUNTPOINT/shared/wp-config.php)"
        if [ "$currentVal" = 'put your unique phrase here' ]; then
          set_config "$unique" "$(head -c1m /dev/urandom | sha1sum | cut -d' ' -f1)"
        fi
      fi
    done

    if [ "$WORDPRESS_TABLE_PREFIX" ]; then
      set_config '$table_prefix' "$WORDPRESS_TABLE_PREFIX"
    fi

    if [ "$WORDPRESS_DEBUG" ]; then
      set_config 'WP_DEBUG' 1 boolean
    fi

    TERM=dumb php -- <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

// https://codex.wordpress.org/Editing_wp-config.php#MySQL_Alternate_Port
//   "hostname:port"
// https://codex.wordpress.org/Editing_wp-config.php#MySQL_Sockets_or_Pipes
//   "hostname:unix-socket-path"
list($host, $socket) = explode(':', getenv('WORDPRESS_DB_HOST'), 2);
$port = 0;
if (is_numeric($socket)) {
  $port = (int) $socket;
  $socket = null;
}
$user = getenv('WORDPRESS_DB_USER');
$pass = getenv('WORDPRESS_DB_PASSWORD');
$dbName = getenv('WORDPRESS_DB_NAME');

$maxTries = 10;
do {
  $mysql = new mysqli($host, $user, $pass, '', $port, $socket);
  if ($mysql->connect_error) {
    fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
    --$maxTries;
    if ($maxTries <= 0) {
      exit(1);
    }
    sleep(3);
  }
} while ($mysql->connect_error);

if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($dbName) . '`')) {
  fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
  $mysql->close();
  exit(1);
}

$mysql->close();
EOPHP
fi

# make sure our shared content locations are present
if [ ! -d $MOUNTPOINT/shared ]; then
    mkdir -p $MOUNTPOINT/shared
    chown www-data:www-data $MOUNTPOINT/shared
    chmod 755 $MOUNTPOINT/shared
fi

# init wp-content if it's not already there
if [ ! -d $MOUNTPOINT/shared/wp-content ]; then
    cp -Rp $MOUNTPOINT/release/wordpress/wp-content $MOUNTPOINT/shared/
    chown -R www-data $MOUNTPOINT/shared/wp-content
fi

# set security
chmod 640 $MOUNTPOINT/shared/wp-config.php
chown www-data $MOUNTPOINT/shared/wp-config.php

# final cleanup
rm -f $MOUNTPOINT/shared/sed* || true

# now that we're definitely done writing configuration, let's clear out the relevant envrionment variables (so that stray "phpinfo()" calls don't leak secrets from our code)
for e in "${envs[@]}"; do
    unset "$e"
done

exec "$@"
