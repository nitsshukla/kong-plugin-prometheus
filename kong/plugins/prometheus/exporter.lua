local worker_cache = require("kong.plugins.prometheus.worker_cache")

local find = string.find
local select = select

local DEFAULT_BUCKETS = { 1, 2, 5, 7, 10, 15, 20, 25, 30, 40, 50, 60, 70,
                          80, 90, 100, 200, 300, 400, 500, 1000,
                          2000, 5000, 10000, 30000, 60000 }

local metrics = {}
local prometheus

local metrics_meta = {
  nginx_http_current_connections = {
    type        = "gauge",
    description = "Number of HTTP connections",
    labels      = {"state"},
  },
  db_reachable = {
    type        = "gauge",
    description = "Datastore reachable from Kong, 0 is unreachable",
    labels      = nil,
  },

  http_status = {
    type        = "counter",
    description = "HTTP status codes per service in Kong",
    labels      = {"code", "service"},
  },
  bandwidth = {
    type        = "counter",
    description = "Total bandwidth in bytes consumed per service in Kong",
    labels      = {"type", "service"},
  },

  latency = {
    type        = "histogram",
    description = "Latency added by Kong, total request time and upstream latency for each service in Kong",
    labels      = {"type", "service"},
  },

}


--[[
local worker_cache = {
  -- counter or gauge
  nginx_http_current_connections = {
    {"ingress", "service1"} = 111,
    {"egress", "service1"} = 222,
  },
 -- histogram
 nginx_http_current_connections = {
    {"ingress", "service1"} = {
      "1": 1,
      "2": 2,
      "5": 10, 
    },
  },
}
]]

local function sync()
  kong.log.err("sync run ")

  local errors = {}
  local error_count = 0
  for k, v in pairs(worker_cache.cache) do
    local meta = metrics_meta[k]
    if meta.type == "gauge" then
      for label_values, value in pairs(v) do
        kong.log.err("set ", k, value, require("cjson").encode(label_values))
        metrics[k]:set(value, label_values)
      end
    elseif meta.type == "counter" then
      -- TODO: check_labels
      for label_values, value in pairs(v) do
        metrics[k].prometheus:set(k, meta.labels, label_values, value)
      end
    elseif meta.type == "histogram" then
      -- TODO: check_labels
      -- NYI
    end
  end
end


local function init()
  local shm = "prometheus_metrics"
  if not ngx.shared.prometheus_metrics then
    kong.log.err("prometheus: ngx shared dict 'prometheus_metrics' not found")
    return
  end

  prometheus = require("kong.plugins.prometheus.prometheus").init(shm, "kong_")

  for name, meta in pairs(metrics_meta) do
    worker_cache.cache[name] = {}
    metrics[name] = prometheus[meta.type](prometheus, name, meta.description, meta.labels)
  end

end


local function log(message)
  if not metrics then
    kong.log.err("prometheus: can not log metrics because of an initialization "
                 .. "error, please make sure that you've declared "
                 .. "'prometheus_metrics' shared dict in your nginx template")
    return
  end

  local service_name
  if message and message.service then
    service_name = message.service.name or message.service.host
  else
    -- do not record any stats if the service is not present
    return
  end

  worker_cache.inc("http_status", 1,  { message.response.status, service_name })

  worker_cache.inc("bandwidth", 1,  { "ingress", service_name })

  --[[metrics.status:inc(1, { message.response.status, service_name })

  local request_size = tonumber(message.request.size)
  if request_size and request_size > 0 then
    metrics.bandwidth:inc(request_size, { "ingress", service_name })
  end

  local response_size = tonumber(message.response.size)
  if response_size and response_size > 0 then
    metrics.bandwidth:inc(response_size, { "egress", service_name })
  end

  local request_latency = message.latencies.request
  if request_latency and request_latency >= 0 then
    metrics.latency:observe(request_latency, { "request", service_name })
  end

  local upstream_latency = message.latencies.proxy
  if upstream_latency ~= nil and upstream_latency >= 0 then
    metrics.latency:observe(upstream_latency, {"upstream", service_name })
  end

  local kong_proxy_latency = message.latencies.kong
  if kong_proxy_latency ~= nil and kong_proxy_latency >= 0 then
    metrics.latency:observe(kong_proxy_latency, { "kong", service_name })
  end]]--
end


local function collect()
  if not prometheus or not metrics then
    kong.log.err("prometheus: plugin is not initialized, please make sure ",
                 " 'prometheus_metrics' shared dict is present in nginx template")
    return kong.response.exit(500, { message = "An unexpected error occurred" })
  end

  local r = ngx.location.capture "/nginx_status"

  if r.status ~= 200 then
    kong.log.warn("prometheus: failed to retrieve /nginx_status ",
                  "while processing /metrics endpoint")

  else
    local accepted, handled, total = select(3, find(r.body,
                                            "accepts handled requests\n (%d*) (%d*) (%d*)"))
    metrics.nginx_http_current_connections:set(accepted, { "accepted" })
    metrics.nginx_http_current_connections:set(handled, { "handled" })
    metrics.nginx_http_current_connections:set(total, { "total" })
  end

  metrics.nginx_http_current_connections:set(ngx.var.connections_active, { "active" })
  metrics.nginx_http_current_connections:set(ngx.var.connections_reading, { "reading" })
  metrics.nginx_http_current_connections:set(ngx.var.connections_writing, { "writing" })
  metrics.nginx_http_current_connections:set(ngx.var.connections_waiting, { "waiting" })

  -- db reachable?
  local ok, err = kong.db.connector:connect()
  if ok then
    metrics.db_reachable:set(1)

  else
    metrics.db_reachable:set(0)
    kong.log.err("prometheus: failed to reach database while processing",
                 "/metrics endpoint: ", err)
  end

  prometheus:collect()
end


return {
  init    = init,
  log     = log,
  collect = collect,
  sync    = sync,
}
