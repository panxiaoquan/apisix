#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();
log_level('info');
worker_connections(1024);

add_block_preprocessor(sub {
    my ($block) = @_;

    my $http_config = $block->http_config // <<_EOC_;

    server {
        listen 1986;
        server_tokens off;

        location / {
            content_by_lua_block {
                ngx.req.read_body()
                local body = ngx.req.get_body_data()
                ngx.log(ngx.INFO, "mirror uri: ", ngx.var.request_uri)
                ngx.log(ngx.INFO, "mirror host: ", ngx.var.http_host or "<empty>")
                ngx.log(ngx.INFO, "mirror body: ", body or "<empty>")
                ngx.say("mirror")
            }
        }
    }

    server {
        listen 1988;
        server_tokens off;

        location / {
            content_by_lua_block {
                ngx.req.read_body()
                local body = ngx.req.get_body_data()
                ngx.log(ngx.INFO, "mirror upstream uri: ", ngx.var.request_uri)
                ngx.log(ngx.INFO, "mirror upstream host: ", ngx.var.http_host or "<empty>")
                ngx.log(ngx.INFO, "mirror upstream body: ", body or "<empty>")
                ngx.say("mirror-upstream")
            }
        }
    }

    server {
        listen 1987;
        server_tokens off;

        location / {
            content_by_lua_block {
                ngx.req.read_body()
                local body = ngx.req.get_body_data()
                ngx.log(ngx.INFO, "origin uri: ", ngx.var.request_uri)
                ngx.log(ngx.INFO, "origin body: ", body or "<empty>")
                ngx.print(body or "")
            }
        }
    }
_EOC_

    $block->set_value("http_config", $http_config);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: reject grpc body rewrite
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "host": "grpc://127.0.0.1:1986",
                               "body": {
                                   "set": {
                                       "path": "user.name",
                                       "value": "mirror"
                                   }
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- error_code: 400
--- response_body eval
qr/body\.set is not supported for grpc\/grpcs mirror targets/



=== TEST 2: configure route with mirror body rewrite and custom path
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "host": "http://127.0.0.1:1986",
                               "path": "/mirror",
                               "body": {
                                   "set": {
                                       "path": "user.name",
                                       "value": "mirror"
                                   }
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- response_body
passed



=== TEST 3: mirror request body should be rewritten without changing upstream body
--- request
POST /hello?foo=bar
{"user":{"name":"origin"}}
--- more_headers
Content-Type: application/json
--- response_body
{"user":{"name":"origin"}}
--- error_log_like eval
[qr/origin uri: \/hello\?foo=bar/, qr/origin body: \{\"user\":\{\"name\":\"origin\"\}\}/,
 qr/mirror uri: \/mirror\?foo=bar/, qr/mirror body: \{\"user\":\{\"name\":\"mirror\"\}\}/]
--- no_error_log
invalid URL prefix
--- wait: 0.2



=== TEST 4: configure route to create missing nested mirror fields
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "host": "http://127.0.0.1:1986",
                               "body": {
                                   "set": {
                                       "path": "meta.trace_id",
                                       "value": "static-trace"
                                   }
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- response_body
passed



=== TEST 5: mirror request body should create missing objects from empty json
--- request
POST /hello
{}
--- more_headers
Content-Type: application/json
--- response_body
{}
--- error_log_like eval
[qr/origin body: \{\}/, qr/mirror body: \{\"meta\":\{\"trace_id\":\"static-trace\"\}\}/]
--- wait: 0.2



=== TEST 6: reject host and upstream configured together
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "host": "http://127.0.0.1:1986",
                               "upstream": {
                                   "nodes": {
                                       "127.0.0.1:1988": 1
                                   },
                                   "type": "roundrobin"
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- error_code: 400
--- response_body eval
qr/exactly one of `host` or `upstream` must be configured/



=== TEST 7: reject empty target configuration
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "path": "/mirror"
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- error_code: 400
--- response_body eval
qr/exactly one of `host` or `upstream` must be configured/



=== TEST 8: reject non-http upstream scheme
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "upstream": {
                                   "scheme": "grpc",
                                   "nodes": {
                                       "127.0.0.1:1988": 1
                                   },
                                   "type": "roundrobin"
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- error_code: 400
--- response_body eval
qr/upstream\.scheme only supports http or https in proxy-mirror-enhanced/



=== TEST 9: configure route with inline upstream and prefixed path
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "path": "/shadow",
                               "path_concat_mode": "prefix",
                               "upstream": {
                                   "nodes": {
                                       "127.0.0.1:1988": 1
                                   },
                                   "type": "roundrobin",
                                   "pass_host": "rewrite",
                                   "upstream_host": "mirror.example.com"
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- response_body
passed



=== TEST 10: inline upstream mirror should use selected target and rewritten host
--- request
POST /hello?foo=bar
{"user":{"name":"origin"}}
--- more_headers
Content-Type: application/json
--- response_body
{"user":{"name":"origin"}}
--- error_log_like eval
[qr/origin uri: \/hello\?foo=bar/, qr/origin body: \{\"user\":\{\"name\":\"origin\"\}\}/,
 qr/mirror upstream uri: \/shadow\/hello\?foo=bar/, qr/mirror upstream host: mirror\.example\.com/,
 qr/mirror upstream body: \{\"user\":\{\"name\":\"origin\"\}\}/]
--- no_error_log
invalid URL prefix
--- wait: 0.2



=== TEST 11: configure route with inline upstream body rewrite
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "path": "/mirror-upstream",
                               "body": {
                                   "set": {
                                       "path": "user.name",
                                       "value": "mirror"
                                   }
                               },
                               "upstream": {
                                   "nodes": {
                                       "127.0.0.1:1988": 1
                                   },
                                   "type": "roundrobin",
                                   "pass_host": "rewrite",
                                   "upstream_host": "mirror-body.example.com"
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
               end
               ngx.say(body)
           }
       }
--- response_body
passed



=== TEST 12: inline upstream body rewrite should not change origin body
--- request
POST /hello?foo=bar
{"user":{"name":"origin"}}
--- more_headers
Content-Type: application/json
--- response_body
{"user":{"name":"origin"}}
--- error_log_like eval
[qr/origin uri: \/hello\?foo=bar/, qr/origin body: \{\"user\":\{\"name\":\"origin\"\}\}/,
 qr/mirror upstream uri: \/mirror-upstream\?foo=bar/,
 qr/mirror upstream host: mirror-body\.example\.com/,
 qr/mirror upstream body: \{\"user\":\{\"name\":\"mirror\"\}\}/]
--- no_error_log
invalid URL prefix
--- wait: 0.2



=== TEST 13: inline upstream discovery should mirror through discovery nodes
--- config
       location /t {
           content_by_lua_block {
               local t = require("lib.test_admin").test
               local discovery = require("apisix.discovery.init").discovery
               discovery.mock = {
                   nodes = function(service_name)
                       if service_name ~= "mirror-service" then
                           return nil, "unexpected service"
                       end

                       return {
                           {host = "127.0.0.1", port = 1988, weight = 1}
                       }
                   end
               }

               local code, body = t('/apisix/admin/routes/1',
                    ngx.HTTP_PUT,
                    [[{
                        "plugins": {
                            "proxy-mirror-enhanced": {
                               "path": "/discovery",
                               "path_concat_mode": "prefix",
                               "upstream": {
                                   "service_name": "mirror-service",
                                   "discovery_type": "mock",
                                   "type": "roundrobin",
                                   "pass_host": "rewrite",
                                   "upstream_host": "mirror-discovery.example.com"
                               }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1987": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                   }]]
                   )

               if code >= 300 then
                   ngx.status = code
                   ngx.say(body)
                   return
               end

               ngx.sleep(0.2)

               local http = require("resty.http")
               local httpc = http.new()
               local res, err = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port
                                                  .. "/hello?foo=bar", {
                   method = "POST",
                   body = [[{"user":{"name":"origin"}}]],
                   headers = {
                       ["Content-Type"] = "application/json"
                   },
                   keepalive = false,
               })

               if not res then
                   ngx.status = 500
                   ngx.say(err)
                   return
               end

               ngx.status = res.status
               ngx.say(res.body)
           }
       }
--- response_body
{"user":{"name":"origin"}}
--- error_log_like eval
[qr/origin uri: \/hello\?foo=bar/, qr/origin body: \{\"user\":\{\"name\":\"origin\"\}\}/,
 qr/mirror upstream uri: \/discovery\/hello\?foo=bar/,
 qr/mirror upstream host: mirror-discovery\.example\.com/,
 qr/mirror upstream body: \{\"user\":\{\"name\":\"origin\"\}\}/]
--- no_error_log
invalid URL prefix
--- wait: 0.2
