local find = string.find
local select = select

local DEFAULT_BUCKETS = { 1, 2, 5, 7, 10, 15, 20, 25, 30, 40, 50, 60, 70,
                          80, 90, 100, 200, 300, 400, 500, 1000,
                          2000, 5000, 10000, 30000, 60000 }
local metrics = {}
-- prometheus.lua instance
local prometheus

-- use the same counter library shipped with Kong
package.loaded['prometheus_resty_counter'] = require("resty.counter")


local function init()
  local shm = "prometheus_metrics"
  if not ngx.shared.prometheus_metrics then
    kong.log.err("prometheus: ngx shared dict 'prometheus_metrics' not found")
    return
  end

  prometheus = require("kong.plugins.prometheus.prometheus").init(shm, "kong_")

  -- global metrics
  metrics.cutom_errors = prometheus:counter("custom counter of error codes",
                                      "Number of errors",
                                      "{error_type}")
  metrics.connections = prometheus:gauge("nginx_http_current_connections",
                                         "Number of HTTP connections",
                                         {"state"})
  metrics.db_reachable = prometheus:gauge("datastore_reachable",
                                          "Datastore reachable from Kong, " ..
                                          "0 is unreachable")
  local memory_stats = {}
  memory_stats.worker_vms = prometheus:gauge("memory_workers_lua_vms_bytes",
                                             "Allocated bytes in worker Lua VM",
                                             {"pid"})
  memory_stats.shms = prometheus:gauge("memory_lua_shared_dict_bytes",
                                       "Allocated slabs in bytes in a shared_dict",
                                       {"shared_dict"})
  memory_stats.shm_capacity = prometheus:gauge("memory_lua_shared_dict_total_bytes",
                                               "Total capacity in bytes of a shared_dict",
                                               {"shared_dict"})
  memory_stats.kong_lua_memory = prometheus:gauge("memory_lua_total_kilobytes",
                                               "Total capacity in KB of lua memory to be collected by garbage collector",
                                               {"lua_memory_collectgarbage"})
  memory_stats.cpu_load_average = prometheus:gauge("cpu_load_average",
                                               "Load average of CPU as provided by uptime",
                                               {"load_average_over_in_minutes"})
  memory_stats.disk_space_available_in_percentage= prometheus:gauge("disk_space_available_in_percentage",
                                               "Total disk available in percentage",
                                               {"source"})

  local res = kong.node.get_memory_stats()
  for shm_name, value in pairs(res.lua_shared_dicts) do
    memory_stats.shm_capacity:set(value.capacity, {shm_name})
  end

  metrics.memory_stats = memory_stats

  -- per service/route
  metrics.status = prometheus:counter("http_status",
                                      "HTTP status codes per service/route in Kong",
                                      {"code", "service", "route"})
  metrics.latency = prometheus:histogram("latency",
                                         "Latency added by Kong, total " ..
                                         "request time and upstream latency " ..
                                         "for each service/route in Kong",
                                         {"type", "service", "route"},
                                         DEFAULT_BUCKETS) -- TODO make this configurable
  metrics.bandwidth = prometheus:counter("bandwidth",
                                         "Total bandwidth in bytes " ..
                                         "consumed per service/route in Kong",
                                         {"type", "service", "route"})
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

  local route_name
  if message and message.route then
    route_name = message.route.name or message.route.id
  end

  labels_table[1] = service_name
  labels_table[2] = route_name
  labels_table[3] = message.response.status
  metrics.status:inc(1, labels_table)

  local request_size = tonumber(message.request.size)
  if request_size and request_size > 0 then
    labels_table[3] = "ingress"
    metrics.bandwidth:inc(request_size, labels_table)
  end

  local response_size = tonumber(message.response.size)
  if response_size and response_size > 0 then
    labels_table[3] = "egress"
    metrics.bandwidth:inc(response_size, labels_table)
  end

  local request_latency = message.latencies.request
  if request_latency and request_latency >= 0 then
    labels_table[3] = "request"
    metrics.latency:observe(request_latency, labels_table)
  end

  local upstream_latency = message.latencies.proxy
  if upstream_latency ~= nil and upstream_latency >= 0 then
    labels_table[3] = "upstream"
    metrics.latency:observe(upstream_latency, labels_table)
  end

  local kong_proxy_latency = message.latencies.kong
  if kong_proxy_latency ~= nil and kong_proxy_latency >= 0 then
    labels_table[3] = "kong"
    metrics.latency:observe(kong_proxy_latency, labels_table)
  end
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
    metrics.connections:set(accepted, { "accepted" })
    metrics.connections:set(handled, { "handled" })
    metrics.connections:set(total, { "total" })
  end

  metrics.connections:set(ngx.var.connections_active, { "active" })
  metrics.connections:set(ngx.var.connections_reading, { "reading" })
  metrics.connections:set(ngx.var.connections_writing, { "writing" })
  metrics.connections:set(ngx.var.connections_waiting, { "waiting" })

  -- db reachable?
  local ok, err = kong.db.connector:connect()
  if ok then
    metrics.db_reachable:set(1)

  else
    metrics.db_reachable:set(0)
    kong.log.err("prometheus: failed to reach database while processing",
                 "/metrics endpoint: ", err)
  end

  -- memory stats
  local res = kong.node.get_memory_stats()
  for shm_name, value in pairs(res.lua_shared_dicts) do
    metrics.memory_stats.shms:set(value.allocated_slabs, {shm_name})
  end
  local load_avg_result = exec_command([[uptime | grep -P '(?=[load ])average\: [0-9., ]+' -o | grep -P '(?=[average: ]+) [0-9., ]+' -o]])
  if (load_avg_result ~= nil) then
      local load_average_tree = split(load_avg_result, ",")
      if table.maxn(load_average_tree) == 3 then
        metrics.memory_stats.cpu_load_average:set(trim(load_average_tree[1]), {"1"})
        metrics.memory_stats.cpu_load_average:set(trim(load_average_tree[2]), {"5"})
        metrics.memory_stats.cpu_load_average:set(trim(load_average_tree[3]), {"15"})
      else
        report_error("load_average_results_count", table.maxn(load_average_tree))
      end
  end
  metrics.memory_stats.kong_lua_memory:set(tonumber(collectgarbage('count')), {"Total"})
  for i = 1, #res.workers_lua_vms do
    metrics.memory_stats.worker_vms:set(res.workers_lua_vms[i].http_allocated_gc,
                                        {res.workers_lua_vms[i].pid})
  end
  local dfResult = exec_command([[df --total -h --direct --output='pcent,source' | tail -n +2]])
  if dfResult ~= nil then
      local df_results = split(dfResult, "\n");
      for key, value in pairs(df_results) do
        local disk_record = split(value,"%s+")
        if (disk_record[1] ~= nil and disk_record[2] ~= nil) then
          local disk_percentage = disk_record[1]:match("^%s*(.-)%%s*$");
          local disk_percentage_int = tonumber(disk_percentage);
          if (disk_percentage_int ~= nil) then
            metrics.memory_stats.disk_space_available_in_percentage:set(disk_percentage_int, {disk_record[2]})
          end
        end
      end
  end
  
  prometheus:collect()
end

local function get_prometheus()
  if not prometheus then
    kong.log.err("prometheus: plugin is not initialized, please make sure ",
                     " 'prometheus_metrics' shared dict is present in nginx template")
  end
  return prometheus
end

function report_error(error_code)
    metrics.cutom_errors:inc(1, {error_code})
end

function exec_command(cmd)
  local dfCommand = io.popen(cmd)
  local dfCommandResult = dfCommand:read("*a")
  dfCommand:close()
  return dfCommandResult
end

-- Compatibility: Lua-5.1
function trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end
function split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
         table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end

return {
  init        = init,
  init_worker = init_worker,
  log         = log,
  collect     = collect,
  get_prometheus = get_prometheus,
}
