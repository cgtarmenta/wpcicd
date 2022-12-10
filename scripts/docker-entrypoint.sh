#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$1" = 'php-fpm' ]; then
	uid="$(id -u)"
	gid="$(id -g)"
	if [ "$uid" = '0' ]; then
		user='www-data'
		group='www-data'
	else
		user="$uid"
		group="$gid"
	fi

	if [ ! -e index.php ] && [ ! -e wp-includes/version.php ]; then
		# if the directory exists and WordPress doesn't appear to be installed AND the permissions of it are root:root, let's chown it (likely a Docker-created directory)
		if [ "$uid" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
			chown "$user:$group" .
		fi
	fi

fi
entrypoint_log() {
  if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
    echo "$@"
  fi
}

if [ "$1" = "nginx" -o "$1" = "nginx-debug" ]; then
  if /usr/bin/find "/docker-entrypoint.d/" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | read v; then
      entrypoint_log "$0: /docker-entrypoint.d/ is not empty, will attempt to perform configuration"

      entrypoint_log "$0: Looking for shell scripts in /docker-entrypoint.d/"
      find "/docker-entrypoint.d/" -follow -type f -print | sort -V | while read -r f; do
          case "$f" in
              *.envsh)
                  if [ -x "$f" ]; then
                      entrypoint_log "$0: Sourcing $f";
                      . "$f"
                  else
                      # warn on shell scripts without exec bit
                      entrypoint_log "$0: Ignoring $f, not executable";
                  fi
                  ;;
              *.sh)
                  if [ -x "$f" ]; then
                      entrypoint_log "$0: Launching $f";
                      "$f"
                  else
                      # warn on shell scripts without exec bit
                      entrypoint_log "$0: Ignoring $f, not executable";
                  fi
                  ;;
              *) entrypoint_log "$0: Ignoring $f";;
          esac
      done

      entrypoint_log "$0: Configuration complete; ready for start up"
  else
      entrypoint_log "$0: No files found in /docker-entrypoint.d/, skipping configuration"
  fi
fi
exec "$@"