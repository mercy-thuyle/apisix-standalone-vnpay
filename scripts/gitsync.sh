#!/bin/sh
# copy-hook.sh -> test gitsync 4
# GITSYNC_SCOPE_TARGET: master | routes | system
# DC_PROFILE: dc1 | dc2

### C1:
# if [ "$GITSYNC_SCOPE_TARGET" = "routes" ]; then
#     cp /tmp/sync/current/apisix-${DC_PROFILE}.yaml /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml

# elif [ "$GITSYNC_SCOPE_TARGET" = "system" ]; then
#     cp /tmp/sync/current/config-${DC_PROFILE}.yaml /tmp/sync/apisix_config/config-${DC_PROFILE}.yaml
#     cp /tmp/sync/current/plugins/*.lua /tmp/sync/apisix_plugins/

# elif [ "$GITSYNC_SCOPE_TARGET" = "master" ]; then
#     cp /tmp/sync/current/docker-compose.yml /tmp/sync/master_files/docker-compose.yml
# fi

### C2:
case "$GITSYNC_SCOPE_TARGET" in
  routes)
    cp /tmp/sync/current/apisix-${DC_PROFILE}.yaml /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml
    ;;

  system)
    cp /tmp/sync/current/config-${DC_PROFILE}.yaml /tmp/sync/apisix_config/config-${DC_PROFILE}.yaml

    # Sync toàn bộ custom plugins
    if [ -d /tmp/sync/current/plugins_lua ]; then
      cp -r /tmp/sync/current/plugins_lua/*.lua /tmp/sync/plugins_lua/
    fi
    ;;

  master)
    cp /tmp/sync/current/docker-compose.yaml /tmp/docker-compose.yaml

    # Sync toàn bộ scripts
    if [ -d /tmp/sync/current/scripts ]; then
      cp -r /tmp/sync/current/scripts/* /tmp/scripts/
    fi
    ;;

  *)
    echo "Unknown GITSYNC_SCOPE_TARGET: $GITSYNC_SCOPE_TARGET"
    exit 1
    ;;
esac