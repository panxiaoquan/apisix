--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core          = require("apisix.core")
local upstream      = require("apisix.upstream")
local balancer      = require("apisix.balancer")
local schema_def    = require("apisix.schema_def")
local url           = require("net.url")

local math_random = math.random
local setmetatable = setmetatable
local tonumber = tonumber
local tostring = tostring
local has_mod, apisix_ngx_client = pcall(require, "resty.apisix.client")


local plugin_name = "proxy-mirror-enhanced"
local schema = {
    type = "object",
    properties = {
        host = {
            type = "string",
            pattern = [=[^(http(s)?|grpc(s)?):\/\/([\da-zA-Z.-]+|\[[\da-fA-F:]+\])(:\d+)?$]=],
        },
        upstream = schema_def.upstream,
        path = {
            type = "string",
            pattern = [[^/[^?&]+$]],
        },
        path_concat_mode = {
            type = "string",
            default = "replace",
            enum = {"replace", "prefix"},
            description = "the concatenation mode for custom path"
        },
        sample_ratio = {
            type = "number",
            minimum = 0.00001,
            maximum = 1,
            default = 1,
        },
        body = {
            type = "object",
            properties = {
                set = {
                    type = "object",
                    properties = {
                        path = {
                            type = "string",
                            minLength = 1,
                        },
                        value = {
                            oneOf = {
                                {type = "string"},
                                {type = "number"},
                                {type = "boolean"},
                                {type = "object"},
                                {type = "array"},
                            },
                        },
                    },
                    required = {"path", "value"},
                    additionalProperties = false,
                },
            },
            required = {"set"},
            additionalProperties = false,
        },
    },
}

local _M = {
    version = 0.1,
    priority = 1009,
    name = plugin_name,
    schema = schema,
}


local function is_grpc_host(host)
    return core.string.has_prefix(host, "grpc://")
        or core.string.has_prefix(host, "grpcs://")
end


local function is_http_scheme(scheme)
    return scheme == "http" or scheme == "https"
end


local function is_grpc_scheme(scheme)
    return scheme == "grpc" or scheme == "grpcs"
end


local function parse_body_path(path)
    if path == "$" then
        return {}
    end

    if core.string.has_prefix(path, "/") then
        if path == "/" or core.string.has_suffix(path, "/") or path:find("//", 1, true) then
            return nil, "body.set.path contains an empty json pointer segment"
        end

        local segments = {}
        for seg in path:sub(2):gmatch("[^/]+") do
            seg = seg:gsub("~1", "/"):gsub("~0", "~")
            if seg == "" then
                return nil, "body.set.path contains an empty json pointer segment"
            end
            core.table.insert(segments, seg)
        end

        return segments
    end

    if core.string.has_prefix(path, "$.") then
        path = path:sub(3)
    elseif path:sub(1, 1) == "$" then
        return nil, "body.set.path only supports '$' or '$.a.b' as JSONPath syntax"
    end

    if path == ""
        or path:sub(1, 1) == "."
        or path:sub(-1) == "."
        or path:find("..", 1, true)
    then
        return nil, "body.set.path contains an empty segment"
    end

    if path:find("%[") or path:find("%]") then
        return nil, "body.set.path only supports object traversal in this version"
    end

    local segments = {}
    for seg in path:gmatch("[^.]+") do
        if seg == "" then
            return nil, "body.set.path contains an empty segment"
        end
        core.table.insert(segments, seg)
    end

    return segments
end


local function build_mirror_uri(ctx, conf)
    local uri = (ctx.var.upstream_uri and ctx.var.upstream_uri ~= "") and
                ctx.var.upstream_uri or
                ctx.var.uri .. ctx.var.is_args .. (ctx.var.args or "")

    if conf.path then
        if conf.path_concat_mode == "prefix" then
            uri = conf.path .. uri
        else
            uri = conf.path .. ctx.var.is_args .. (ctx.var.args or '')
        end
    end

    return uri
end


local function resolver_host(prop_host)
    local url_decoded = url.parse(prop_host)
    local decoded_host = url_decoded.host
    if not core.utils.parse_ipv4(decoded_host) and not core.utils.parse_ipv6(decoded_host) then
        local ip, err = core.resolver.parse_domain(decoded_host)

        if not ip then
            core.log.error("dns resolver resolves domain: ", decoded_host, " error: ", err,
                            " will continue to use the host: ", decoded_host)
            return url_decoded.scheme, prop_host
        end

        local host = url_decoded.scheme .. "://" .. ip ..
            (url_decoded.port and ":" .. url_decoded.port or "")
        core.log.info(prop_host, " is resolved to: ", host)
        return url_decoded.scheme, host
    end
    return url_decoded.scheme, prop_host
end


local function parse_mirror_host_header(prop_host)
    local parsed = url.parse(prop_host)
    local host = parsed.host
    local port = tonumber(parsed.port)
    local standard_port = upstream.scheme_to_port[parsed.scheme]

    if port and port ~= standard_port then
        host = host .. ":" .. port
    end

    return host
end


local function build_upstream_mirror_host(ctx, up_conf, server)
    local pass_host = up_conf.pass_host or "pass"
    if pass_host == "rewrite" then
        return up_conf.upstream_host
    end

    if pass_host == "node" then
        return server.upstream_host
    end

    if ctx.var.upstream_host and ctx.var.upstream_host ~= "" then
        return ctx.var.upstream_host
    end

    return ctx.var.http_host
end


local function prepare_mirror_upstream(ctx, conf)
    local up_conf = core.table.deepcopy(conf.upstream)
    local route_id = core.table.try_read_attr(ctx, "matched_route", "value", "id") or ctx.conf_id
    local parent = {
        key = "/routes/" .. tostring(route_id) .. "#plugins.proxy-mirror-enhanced.upstream",
        modifiedIndex = ctx.conf_version or 0,
        value = {
            id = route_id,
        },
    }

    upstream.filter_upstream(up_conf, parent)
    up_conf.scheme = up_conf.scheme or "http"
    up_conf.type = up_conf.type or "roundrobin"

    return up_conf
end


local function build_upstream_mirror_target(ctx, conf)
    local up_conf, err = prepare_mirror_upstream(ctx, conf)
    if not up_conf then
        return nil, nil, err
    end

    local mirror_var = setmetatable({}, {__index = ctx.var})
    local mirror_ctx = {
        var = mirror_var,
        consumer_name = ctx.consumer_name,
    }

    local route_id = core.table.try_read_attr(ctx, "matched_route", "value", "id") or ctx.conf_id
    local upstream_key = "proxy_mirror_enhanced#" .. tostring(route_id)
    local code, set_err = upstream.set_by_upstream_conf(up_conf, mirror_ctx, upstream_key,
                                                        ctx.conf_version or 0)
    if code then
        return nil, nil, set_err
    end

    local server, pick_err = balancer.pick_server(nil, mirror_ctx)
    if not server then
        return nil, nil, pick_err
    end

    local uri = build_mirror_uri(ctx, conf)
    local target = up_conf.scheme .. "://" .. server.host .. ":" .. server.port .. uri
    local host = build_upstream_mirror_host(ctx, up_conf, server)
    return target, host
end


local function build_mirror_body(conf)
    local path_segments, path_err = parse_body_path(conf.body.set.path)
    if not path_segments then
        return nil, path_err
    end

    local body, err = core.request.get_body()
    if err then
        return nil, "failed to read request body: " .. err
    end

    local body_tab = {}
    if body then
        body_tab, err = core.json.decode(body)
        if not body_tab then
            return nil, "failed to parse request body as JSON: " .. err
        end
    end

    local value = core.table.deepcopy(conf.body.set.value)
    if #path_segments == 0 then
        body_tab = value

    else
        if type(body_tab) ~= "table"
            or (next(body_tab) ~= nil and core.table.isarray(body_tab))
        then
            return nil, "request body must be a JSON object when body.set.path is not '$'"
        end

        local parent = body_tab
        for i = 1, #path_segments - 1 do
            local seg = path_segments[i]
            local child = parent[seg]
            if child == nil then
                child = {}
                parent[seg] = child
            elseif type(child) ~= "table"
                or (next(child) ~= nil and core.table.isarray(child))
            then
                return nil, "body.set.path segment [" .. seg .. "] does not point to a JSON object"
            end

            parent = child
        end

        parent[path_segments[#path_segments]] = value
    end

    local new_body, encode_err = core.json.encode(body_tab)
    if not new_body then
        return nil, "failed to encode mirrored request body: " .. encode_err
    end

    return new_body
end


local function enable_standard_mirror(ctx, conf)
    local target
    local host

    if conf.upstream then
        local err
        target, host, err = build_upstream_mirror_target(ctx, conf)
        if not target then
            return nil, err
        end

        ctx.var.upstream_mirror_enhanced_standard_uri = target
        ctx.var.upstream_mirror_enhanced_host = host
        return true
    end

    local uri = build_mirror_uri(ctx, conf)
    local scheme, mirror_host = resolver_host(conf.host)
    if is_http_scheme(scheme) then
        ctx.var.upstream_mirror_enhanced_standard_uri = mirror_host .. uri
        ctx.var.upstream_mirror_enhanced_host = parse_mirror_host_header(conf.host)
        return true
    end

    ctx.var.upstream_mirror_host = mirror_host
    ctx.var.upstream_mirror_uri = mirror_host .. uri
    return true
end


local function enable_body_mirror(ctx, conf)
    local mirror_body, err = build_mirror_body(conf)
    if not mirror_body then
        return nil, err
    end

    local target
    local host
    if conf.upstream then
        target, host, err = build_upstream_mirror_target(ctx, conf)
        if not target then
            return nil, err
        end
    else
        local uri = build_mirror_uri(ctx, conf)
        local _, mirror_host = resolver_host(conf.host)
        target = mirror_host .. uri
        host = parse_mirror_host_header(conf.host)
    end

    ctx.var.upstream_mirror_enhanced_uri = target
    ctx.var.upstream_mirror_enhanced_host = host
    ctx.var.upstream_mirror_body = mirror_body
    ctx.var.upstream_mirror_content_type = "application/json"
    return true
end


local function enable_mirror(ctx, conf)
    if conf.body and conf.body.set then
        return enable_body_mirror(ctx, conf)
    end

    return enable_standard_mirror(ctx, conf)
end


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if (conf.host and conf.upstream) or (not conf.host and not conf.upstream) then
        return false, "exactly one of `host` or `upstream` must be configured"
    end

    if conf.upstream then
        ok, err = upstream.check_upstream_conf(conf.upstream)
        if not ok then
            return false, err
        end

        local scheme = conf.upstream.scheme or "http"
        if not is_http_scheme(scheme) then
            return false, "upstream.scheme only supports http or https in proxy-mirror-enhanced"
        end
    end

    if conf.body and conf.body.set then
        local _, path_err = parse_body_path(conf.body.set.path)
        if path_err then
            return false, path_err
        end

        if (conf.host and is_grpc_host(conf.host))
            or (conf.upstream and is_grpc_scheme(conf.upstream.scheme or "http"))
        then
            return false, "body.set is not supported for grpc/grpcs mirror targets"
        end
    end

    return true
end


function _M.rewrite(conf, ctx)
    core.log.info("proxy mirror enhanced plugin rewrite phase, conf: ",
                  core.json.delay_encode(conf))

    local should_mirror = conf.sample_ratio == 1
    if not should_mirror then
        local val = math_random()
        core.log.info("mirror request sample_ratio conf: ", conf.sample_ratio,
                      ", random value: ", val)
        should_mirror = val < conf.sample_ratio
    end

    if not should_mirror then
        return
    end

    local ok, err = enable_mirror(ctx, conf)
    if not ok then
        core.log.warn("failed to enable proxy mirror enhanced request: ", err)
        return
    end

    ctx.enable_mirror = true
    if has_mod then
        apisix_ngx_client.enable_mirror()
    end
end


return _M
