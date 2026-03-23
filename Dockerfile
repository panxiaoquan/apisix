ARG BASE_IMAGE=hub.i.basemind.com/stepcloud/gateway/apisix:3.14.1-ubuntu
FROM ${BASE_IMAGE}

# Bundle the custom plugin and the APISIX runtime changes it depends on.
COPY apisix/plugins/proxy-mirror-enhanced.lua /usr/local/apisix/apisix/plugins/proxy-mirror-enhanced.lua
COPY apisix/plugins/forward-auth.lua /usr/local/apisix/apisix/plugins/forward-auth.lua
COPY apisix/cli/config.lua /usr/local/apisix/apisix/cli/config.lua
COPY apisix/cli/ngx_tpl.lua /usr/local/apisix/apisix/cli/ngx_tpl.lua
COPY apisix/cli/ops.lua /usr/local/apisix/apisix/cli/ops.lua
COPY apisix/consumer.lua /usr/local/apisix/apisix/consumer.lua
COPY apisix/core/ctx.lua /usr/local/apisix/apisix/core/ctx.lua
COPY apisix/upstream.lua /usr/local/apisix/apisix/upstream.lua
COPY apisix/discovery/consul/init.lua /usr/local/apisix/apisix/discovery/consul/init.lua
COPY apisix/discovery/consul/schema.lua /usr/local/apisix/apisix/discovery/consul/schema.lua

# Keep the example config in sync inside the image for reference/debugging.
COPY conf/config.yaml.example /usr/local/apisix/conf/config.yaml.example
