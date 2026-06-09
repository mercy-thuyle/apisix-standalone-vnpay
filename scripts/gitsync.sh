#!/bin/sh
# gitsync.sh
## DC_PROFILE: dc1 | dc2 (từ .env)

#cp /tmp/sync/current/docker-compose.yaml /tmp/docker-compose.yaml

#cp /tmp/sync/current/conf_system/config-${DC_PROFILE}.yaml /tmp/apisix_config/config-${DC_PROFILE}.yaml

cp /tmp/sync/current/conf_routes/apisix-${DC_PROFILE}.yaml /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml

cp /tmp/sync/current/scripts/gitsync.sh /tmp/scripts/gitsync.sh

# if [ -d /tmp/sync/current/plugins ]; then
#   cp -r /tmp/sync/current/plugins/*.lua /tmp/sync/plugins/
# fi

## TH nhiều nhánh
## GITSYNC_SCOPE_TARGET: main | routes | system
# case "$GITSYNC_SCOPE_TARGET" in
#   routes)
#     cp /tmp/sync/current/apisix-${DC_PROFILE}.yaml /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml
#     ;;

#   system)
#     cp /tmp/sync/current/config-${DC_PROFILE}.yaml /tmp/sync/apisix_config/config-${DC_PROFILE}.yaml

#     # Sync toàn bộ custom plugins
#     if [ -d /tmp/sync/current/plugins_lua ]; then
#       cp -r /tmp/sync/current/plugins_lua/*.lua /tmp/sync/plugins_lua/
#     fi
#     ;;

#   master)
#     cp /tmp/sync/current/docker-compose.yaml /tmp/docker-compose.yaml

#     # Sync toàn bộ scripts
#     if [ -d /tmp/sync/current/scripts ]; then
#       cp -r /tmp/sync/current/scripts/* /tmp/scripts/
#     fi
#     ;;

#   *)
#     echo "Unknown GITSYNC_SCOPE_TARGET: $GITSYNC_SCOPE_TARGET"
#     exit 1
#     ;;
# esac