local helpers = require "spec.helpers"
local cjson = require "cjson"

local function insert_apis(arr)
  if type(arr) ~= "table" then
    return error("expected arg #1 to be a table", 2)
  end

  helpers.dao:truncate_tables()

  for i = 1, #arr do
    assert(helpers.dao.apis:insert(arr[i]))
  end
end

describe("Router", function()
  local client

  before_each(function()
    client = helpers.proxy_client()
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)

  describe("no APIs match", function()

    setup(function()
      helpers.dao:truncate_tables()
      assert(helpers.start_kong())
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("responds 404 if no API matches", function()
      local res = assert(client:send {
        method = "GET",
        headers = {
          host = "inexistent.com"
        }
      })

      local body = assert.response(res).has_status(404)
      local json = cjson.decode(body)
      assert.matches("^kong/", res.headers.server)
      assert.equal("no API found with those values", json.message)
    end)
  end)

  describe("use-cases", function()

    setup(function()
      insert_apis {
        {
          name = "api-1",
          upstream_url = "http://httpbin.org",
          methods = { "GET" },
        },
        {
          name = "api-2",
          upstream_url = "http://httpbin.org",
          methods = { "POST", "PUT" },
          uris = { "/post", "/put" },
          strip_uri = false,
        },
        {
          name = "api-3",
          upstream_url = "http://httpbin.org/status",
          uris = { "/httpbin" },
          strip_uri = true,
        },
        {
          name = "api-4",
          upstream_url = "http://httpbin.org/basic-auth",
          uris = { "/user" },
          strip_uri = false,
        }
      }

      assert(helpers.start_kong())
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("restricts an API to its methods if specified", function()
      -- < HTTP/1.1 POST /post
      -- > 200 OK
      local res = assert(client:send {
        method = "POST",
        path = "/post",
        headers = { ["kong-debug"] = 1 },
      })

      assert.response(res).has_status(200)
      assert.equal("api-2", res.headers["kong-api-name"])

      -- < HTTP/1.1 DELETE /post
      -- > 404 NOT FOUND
      res = assert(client:send {
        method = "DELETE",
        path = "/post",
        headers = { ["kong-debug"] = 1 },
      })

      assert.response(res).has_status(404)
      assert.is_nil(res.headers["kong-api-name"])
    end)

    it("routes by method-only if no other match is found", function()
      local res = assert(client:send {
        method = "GET",
        path = "/get",
        headers = { ["kong-debug"] = 1 },
      })

      assert.response(res).has_status(200)
      assert.equal("api-1", res.headers["kong-api-name"])
    end)

    describe("API with a path component in its upstream_url", function()
      it("with strip_uri = true", function()
        local res = assert(client:send {
          method = "GET",
          path = "/httpbin/201",
          headers = { ["kong-debug"] = 1 },
        })

        assert.res_status(201, res)
        assert.equal("api-3", res.headers["kong-api-name"])
      end)
    end)

    it("with strip_uri = false", function()
        local res = assert(client:send {
          method = "GET",
          path = "/user/passwd",
          headers = { ["kong-debug"] = 1 },
        })

        assert.res_status(401, res)
        assert.equal("api-4", res.headers["kong-api-name"])
    end)
  end)

  describe("invalidation", function()
    local admin_client

    setup(function()
      helpers.dao:truncate_tables()
      assert(helpers.start_kong())

      admin_client = helpers.admin_client()
    end)

    teardown(function()
      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong()
    end)

    it("updates itself when updating APIs from the Admin API", function()
      local res = assert(client:send {
        method = "GET",
        headers = {
          host = "api.com"
        }
      })
      local body = assert.response(res).has_status(404)
      local json = cjson.decode(body)
      assert.matches("^kong/", res.headers.server)
      assert.equal("no API found with those values", json.message)

      local admin_res = assert(admin_client:send {
        method = "POST",
        path = "/apis",
        body = {
          name = "my-api",
          upstream_url = "http://httpbin.org",
          hosts = "api.com",
        },
        headers = { ["Content-Type"] = "application/json" },
      })
      assert.response(admin_res).has_status(201)

      ngx.sleep(1)

      res = assert(client:send {
        method = "GET",
        headers = {
          host = "api.com"
        }
      })
      assert.response(res).has_status(200)

      admin_res = assert(admin_client:send {
        method = "PATCH",
        path = "/apis/my-api",
        body = {
          hosts = "api.com,foo.com",
          uris = "/foo",
          strip_uri = true,
        },
        headers = { ["Content-Type"] = "application/json" },
      })
      assert.response(admin_res).has_status(200)

      ngx.sleep(1)

      res = assert(client:send {
        method = "GET",
        headers = {
          host = "foo.com"
        }
      })
      assert.response(res).has_status(404)

      res = assert(client:send {
        method = "GET",
        path = "/foo",
        headers = {
          host = "foo.com"
        }
      })
      assert.response(res).has_status(200)
    end)
  end)

  describe("preserve_host", function()

    setup(function()
      insert_apis {
        {
          name = "api-1",
          preserve_host = true,
          upstream_url = "http://localhost:9999/headers-inspect",
          hosts = "preserved.com",
        },
        {
          name = "api-2",
          preserve_host = false,
          upstream_url = "http://localhost:9999/headers-inspect",
          hosts = "discarded.com",
        },
        {
          name = "api-3",
          preserve_host = true,
          upstream_url = "http://localhost:9999/headers-inspect",
          uris = { "/api-3" },
        }
      }

      assert(helpers.start_kong {
        nginx_conf = "spec/fixtures/custom_nginx.template",
      })
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    describe(" = false (default)", function()
      it("uses hostname from upstream_url", function()
        local res = assert(client:send {
          method = "GET",
          path = "/get",
          headers = { ["Host"] = "discarded.com" },
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.matches("localhost", json.host, nil, true) -- not testing :port
      end)

      it("uses port value from upstream_url if not default", function()
        local res = assert(client:send {
          method = "GET",
          path = "/get",
          headers = { ["Host"] = "discarded.com" },
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.matches(":9999", json.host, nil, true) -- not testing hostname
      end)
    end)

    describe(" = true", function()
      it("forwards request Host", function()
        local res = assert(client:send {
          method = "GET",
          path = "/",
          headers = { ["Host"] = "preserved.com" },
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("preserved.com", json.host)
      end)

      it("forwards request Host:Port even if port is default", function()
        local res = assert(client:send {
          method = "GET",
          path = "/get",
          headers = { ["Host"] = "preserved.com:80" },
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("preserved.com:80", json.host)
      end)

      it("forwards request Host:Port if port isn't default", function()
        local res = assert(client:send {
          method = "GET",
          path = "/get",
          headers = { ["Host"] = "preserved.com:123" },
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("preserved.com:123", json.host)
      end)

      it("forwards request Host if matching without 'hosts' rules", function()
        local res = assert(client:send {
          method = "GET",
          path = "/api-3",
          headers = { ["Host"] = "keep-me.com" },
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("keep-me.com", json.host)
      end)
    end)
  end)

  describe("edge-cases", function()

    setup(function()
      insert_apis {
        {
          name = "root-uri",
          upstream_url = "http://httpbin.org",
          uris = "/",
        },
        {
          name = "fixture-api",
          upstream_url = "http://httpbin.org",
          uris = "/foobar",
        },
      }

      assert(helpers.start_kong())
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("root / [uri] for a catch-all rule", function()
      local res = assert(client:send {
        method = "GET",
        path = "/get",
        headers = { ["kong-debug"] = 1 }
      })

      assert.response(res).has_status(200)
      assert.equal("root-uri", res.headers["kong-api-name"])

      res = assert(client:send {
        method = "GET",
        path = "/foobar/get",
        headers = { ["kong-debug"] = 1 }
      })

      assert.response(res).has_status(200)
      assert.equal("fixture-api", res.headers["kong-api-name"])
    end)
  end)


  describe("trailing slash", function()

    setup(function()
      insert_apis {
        {
          name         = "strip-uri-1",
          upstream_url = "http://localhost:9999/",
          hosts        = {
            "localbin-1.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-2",
          upstream_url = "http://localhost:9999/get/foo",
          hosts        = {
            "localbin-2.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-3",
          upstream_url = "http://localhost:9999/get/foo/",
          hosts        = {
            "localbin-3.com",
          },
          uris        = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-4",
          strip_uri    = true,
          upstream_url = "http://localhost:9999/",
          hosts        = {
            "localbin-4.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-5",
          strip_uri    = true,
          upstream_url = "http://localhost:9999/get/foo",
          hosts        = {
            "localbin-5.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-6",
          strip_uri    = true,
          upstream_url = "http://localhost:9999/get/foo/",
          hosts        = {
            "localbin-6.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-7",
          strip_uri    = false,
          upstream_url = "http://localhost:9999/",
          hosts        = {
            "localbin-7.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-8",
          strip_uri    = false,
          upstream_url = "http://localhost:9999/get/foo",
          hosts        = {
            "localbin-8.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
        {
          name         = "strip-uri-9",
          strip_uri    = false,
          upstream_url = "http://localhost:9999/get/foo/",
          hosts        = {
            "localbin-9.com",
          },
          uris         = {
            "/",
            "/get/foo",
          }
        },
      }

      assert(helpers.start_kong {
        nginx_conf = "spec/fixtures/custom_nginx.template",
      })
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    local function check(upstream_uri, request_uri, expected_uri, strip_uri)
      return function()
        local i = 1

        if strip_uri == true then
          i = i + 3
        elseif strip_uri == false then
          i = i + 6
        end

        if upstream_uri ~= "/" then
          i = i + 1
          if string.sub(upstream_uri, -1) == "/" then
            i = i + 1
          end
        end

        local res = assert(client:send {
          method  = "GET",
          path    = request_uri,
          headers = {
            ["Host"] = "localbin-" .. i .. ".com",
          }
        })

        local json = assert.res_status(200, res)
        local data = cjson.decode(json)

        assert.equal(expected_uri, data.server.request_uri)
      end
    end

    local checks = {
      { "/",         "/",         "/",                 nil   },
      { "/",         "/get/foo",  "/",                 nil   },
      { "/",         "/get/foo/", "/",                 nil   },
      { "/get/foo",  "/",         "/get/foo",          nil   },
      { "/get/foo/", "/",         "/get/foo/",         nil   },
      { "/get/foo",  "/get/foo",  "/get/foo",          nil   },
      { "/get/foo/", "/get/foo",  "/get/foo",          nil   },
      { "/get/foo",  "/get/foo/", "/get/foo/",         nil   },
      { "/get/foo/", "/get/foo/", "/get/foo/",         nil   },
      { "/",         "/",         "/",                 true  },
      { "/",         "/get/foo",  "/",                 true  },
      { "/",         "/get/foo/", "/",                 true  },
      { "/get/foo",  "/",         "/get/foo",          true  },
      { "/get/foo/", "/",         "/get/foo/",         true  },
      { "/get/foo",  "/get/foo",  "/get/foo",          true  },
      { "/get/foo/", "/get/foo",  "/get/foo",          true  },
      { "/get/foo",  "/get/foo/", "/get/foo/",         true  },
      { "/get/foo/", "/get/foo/", "/get/foo/",         true  },
      { "/",         "/",         "/",                 false },
      { "/",         "/get/foo",  "/get/foo",          false },
      { "/",         "/get/foo/", "/get/foo/",         false },
      { "/get/foo",  "/",         "/get/foo",          false },
      { "/get/foo/", "/",         "/get/foo/",         false },
      { "/get/foo",  "/get/foo",  "/get/foo/get/foo",  false },
      { "/get/foo/", "/get/foo",  "/get/foo/get/foo",  false },
      { "/get/foo",  "/get/foo/", "/get/foo/get/foo/", false },
      { "/get/foo/", "/get/foo/", "/get/foo/get/foo/", false },
    }

    local unpack = table.unpack or unpack

    for _, args in ipairs(checks) do

      local config = "(strip_uri = n/a)"

      if args[4] == true then
        config = "(strip_uri = on) "
      elseif args[4] == false then
        config = "(strip_uri = off)"
      end

      local space = string.sub(args[1], -1) == "/" and "" or " "

      it(config .. " is not appended to upstream uri " .. args[1] .. space .. " when requesting " .. args[2],
        check(unpack(args)))
    end
  end)
end)
