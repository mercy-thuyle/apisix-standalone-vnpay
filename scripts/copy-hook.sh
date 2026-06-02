#!/bin/sh
# copy-hook.sh
# HOOK_TYPE: routes | system
# DC_PROFILE: dc1 | dc2

if [ "$HOOK_TYPE" = "routes" ]; then
    cp /tmp/sync/current/apisix-${DC_PROFILE}.yaml \
       /tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml

elif [ "$HOOK_TYPE" = "system" ]; then
    cp /tmp/sync/current/config-${DC_PROFILE}.yaml \
       /tmp/sync/apisix_config/config-${DC_PROFILE}.yaml
fi