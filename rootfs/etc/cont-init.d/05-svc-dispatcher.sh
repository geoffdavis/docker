#!/usr/bin/with-contenv bash

# From https://github.com/docker-library/mariadb/blob/master/docker-entrypoint.sh#L21-L41
# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
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

DB_PORT=${DB_PORT:-3306}
DB_DATABASE=${DB_DATABASE:-librenms}
DB_USERNAME=${DB_USERNAME:-librenms}
DB_TIMEOUT=${DB_TIMEOUT:-60}

SIDECAR_DISPATCHER=${SIDECAR_DISPATCHER:-0}
#DISPATCHER_NODE_ID=${DISPATCHER_NODE_ID:-dispatcher1}

#REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}
file_env 'REDIS_PASSWORD'
REDIS_DB=${REDIS_DB:-0}

# Continue only if sidecar dispatcher container
if [ "$SIDECAR_DISPATCHER" != "1" ]; then
  exit 0
fi

echo ">>"
echo ">> Sidecar dispatcher container detected"
echo ">>"

file_env 'DB_PASSWORD'
if [ -z "$DB_PASSWORD" ]; then
  >&2 echo "ERROR: Either DB_PASSWORD or DB_PASSWORD_FILE must be defined"
  exit 1
fi

dbcmd="mysql -h ${DB_HOST} -P ${DB_PORT} -u "${DB_USERNAME}" "-p${DB_PASSWORD}""
unset DB_PASSWORD

echo "Waiting ${DB_TIMEOUT}s for database to be ready..."
counter=1
while ! ${dbcmd} -e "show databases;" > /dev/null 2>&1; do
  sleep 1
  counter=$((counter + 1))
  if [ ${counter} -gt ${DB_TIMEOUT} ]; then
    >&2 echo "ERROR: Failed to connect to database on $DB_HOST"
    exit 1
  fi;
done
while ! grep "1" /data/.migrated > /dev/null 2>&1; do
  sleep 1
  counter=$((counter + 1))
  if [ ${counter} -gt ${DB_TIMEOUT} ]; then
    >&2 echo "ERROR: Database migration not processed on $DB_HOST"
    exit 1
  fi;
done
echo "Database ready!"
while ! ${dbcmd} -e "desc $DB_DATABASE.poller_cluster;" > /dev/null 2>&1; do
  sleep 1
  counter=$((counter + 1))
  if [ ${counter} -gt ${DB_TIMEOUT} ]; then
    >&2 echo "ERROR: Table $DB_DATABASE.poller_cluster does not exist on $DB_HOST"
    exit 1
  fi;
done

# Node ID
if [ ! -f "/data/.env" ]; then
  >&2 echo "ERROR: /data/.env file does not exist. Please run the main container first"
  exit 1
fi
cat "/data/.env" >> "${LIBRENMS_PATH}/.env"
if [ -n "$DISPATCHER_NODE_ID" ]; then
  echo "NODE_ID: $DISPATCHER_NODE_ID"
  sed -i "s|^NODE_ID=.*|NODE_ID=$DISPATCHER_NODE_ID|g" "${LIBRENMS_PATH}/.env"
fi

# Redis
if [ -z "$REDIS_HOST" ]; then
  >&2 echo "ERROR: REDIS_HOST must be defined"
  exit 1
fi
echo "Setting Redis"
cat >> ${LIBRENMS_PATH}/.env <<EOL
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}
EOL

# Create service
mkdir -p /etc/services.d/dispatcher
cat > /etc/services.d/dispatcher/run <<EOL
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid ${PUID}:${PGID}
/opt/librenms/librenms-service.py -v
EOL
chmod +x /etc/services.d/dispatcher/run
