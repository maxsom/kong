-- ALF serializer module.
-- ALF is the format supported by Mashape Analytics (http://apianalytics.com)
--
-- This module represents _one_ ALF, zhich has _one_ ALF entry.
-- It used to be a representation of one ALF with several entries, but ALF
-- had its `clientIPAddress` moved to the root level of ALF, hence breaking
-- this implementation.
--
-- # Usage:
--
--   ## Create the ALF like so:
--     local alf = ALFSerializer:new_alf(ngx, serviceToken, environment)
--
-- - ALF specifications: https://github.com/Mashape/api-log-format
-- - Nginx lua module documentation: http://wiki.nginx.org/HttpLuaModule
-- - ngx_http_core_module: http://wiki.nginx.org/HttpCoreModule#.24http_HEADER

local stringy = require "stringy"

local EMPTY_ARRAY_PLACEHOLDER = "__empty_array_placeholder__"

-- Transform a key/value lua table into an array of elements with `name`, `value`.
-- Since Lua won't recognize {} as an empty array but an empty object, we need to force it
-- to be an array, hence we will do "[__empty_array_placeholder__]".
-- Then once the ALF will be stringified, we will remove the placeholder so the only left element will be "[]".
-- @param  `hash`  key/value dictionary to serialize.
-- @param  `fn`    Some function to execute at each key iteration, with the key and value as parameters.
-- @return `array` an array, or nil
local function dic_to_array(hash, fn)
  if not fn then fn = function() end end
  local arr = {}
  for k, v in pairs(hash) do
    -- If the key has multiple values, v will be an array of all those values for the same key
    -- hence we have to add multiple entries to the output array for that same key.
    if type(v) ~= "table" then
      v = {v}
    end
    for _, val in ipairs(v) do
      table.insert(arr, {name = k, value = val})
      fn(k, val)
    end
  end

  if #arr > 0 then
    return arr
  else
    return {EMPTY_ARRAY_PLACEHOLDER}
  end
end

local _M = {}

-- Serialize `ngx` into one ALF entry.
-- For performance reasons, it tries to use the NGINX Lua API instead of
-- ngx_http_core_module when possible.
-- Public for unit testing.
function _M.serialize_entry(ngx)
  -- ALF properties computation. Properties prefixed with 'alf_' will belong to the ALF entry.
  -- other properties are used to compute the ALF properties.

  -- bodies
  local analytics_data = ngx.ctx.analytics

  local alf_req_body = analytics_data.req_body or ""
  local alf_res_body = analytics_data.res_body or ""

  -- timers
  local proxy_started_at, proxy_ended_at = ngx.ctx.proxy_started_at, ngx.ctx.proxy_ended_at

  local alf_started_at = ngx.req.start_time()

  -- First byte sent to upstream - first byte received from client
  local alf_send_time = proxy_started_at - alf_started_at * 1000

  -- Time waiting for the upstream response
  local upstream_response_time = 0
  local upstream_response_times = ngx.var.upstream_response_time
  if not upstream_response_times or upstream_response_times == "-" then
    -- client aborted the request
    return
  end

  upstream_response_times = stringy.split(upstream_response_times, ", ")
  for _, val in ipairs(upstream_response_times) do
    upstream_response_time = upstream_response_time + val
  end
  local alf_wait_time = upstream_response_time * 1000

  -- upstream response fully received - upstream response 1 byte received
  local alf_receive_time = analytics_data.response_received and analytics_data.response_received - proxy_ended_at or -1

  -- Compute the total time. If some properties were unavailable
  -- (because the proxying was aborted), then don't add the value.
  local alf_time = 0
  for _, timer in ipairs({alf_send_time, alf_wait_time, alf_receive_time}) do
    if timer > 0 then
      alf_time = alf_time + timer
    end
  end

  -- headers and headers size
  local req_headers_str, res_headers_str = "", ""
  local req_headers = ngx.req.get_headers()
  local res_headers = ngx.resp.get_headers()

  local alf_req_headers_arr = dic_to_array(req_headers, function(k, v) req_headers_str = req_headers_str..k..v end)
  local alf_res_headers_arr = dic_to_array(res_headers, function(k, v) res_headers_str = res_headers_str..k..v end)
  local alf_req_headers_size = string.len(req_headers_str)
  local alf_res_headers_size = string.len(res_headers_str)

  -- mimeType, defaulting to "application/octet-stream"
  local alf_req_mimeType = req_headers["Content-Type"] and req_headers["Content-Type"] or "application/octet-stream"
  local alf_res_mimeType = res_headers["Content-Type"] and res_headers["Content-Type"] or "application/octet-stream"

  return {
    startedDateTime = os.date("!%Y-%m-%dT%TZ", alf_started_at),
    time = alf_time,
    request = {
      method = ngx.req.get_method(),
      url = ngx.var.scheme.."://"..ngx.var.host..ngx.var.uri,
      httpVersion = "HTTP/"..ngx.req.http_version(),
      queryString = dic_to_array(ngx.req.get_uri_args()),
      headers = alf_req_headers_arr,
      headersSize = alf_req_headers_size,
      cookies = {EMPTY_ARRAY_PLACEHOLDER},
      bodySize = string.len(alf_req_body),
      postData = {
        mimeType = alf_req_mimeType,
        params = dic_to_array(ngx.req.get_post_args()),
        text = alf_req_body
      }
    },
    response = {
      status = ngx.status,
      statusText = "", -- can't find a way to retrieve that
      httpVersion = "", -- can't find a way to retrieve that either
      headers = alf_res_headers_arr,
      headersSize = alf_res_headers_size,
      cookies = {EMPTY_ARRAY_PLACEHOLDER},
      bodySize = tonumber(ngx.var.body_bytes_sent),
      redirectURL = "",
      content = {
        size = tonumber(ngx.var.body_bytes_sent),
        mimeType = alf_res_mimeType,
        text = alf_res_body
      }
    },
    cache = {},
    timings = {
      send = alf_send_time,
      wait = alf_wait_time,
      receive = alf_receive_time,
      blocked = -1,
      connect = -1,
      dns = -1,
      ssl = -1
    }
  } -- end of entry
end

function _M.new_alf(ngx, token, environment)
  if not ngx then
    error("Missing ngx context", 2)
  elseif not token then
    error("Mashape Analytics serviceToken required", 2)
  end

  local entry = _M.serialize_entry(ngx)
  if not entry then
    return
  end

  return {
    version = "1.0.0",
    serviceToken = token,
    environment = environment,
    clientIPAddress = ngx.var.remote_addr,
    har = {
      log = {
        version = "1.2",
        creator = {
          name = "mashape-analytics-agent-kong",
          version = "1.0.1"
        },
        entries = {_M.serialize_entry(ngx)}
      }
    }
  }
end

return _M
