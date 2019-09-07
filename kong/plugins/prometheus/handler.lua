local exporter = require "kong.plugins.prometheus.exporter"
local basic_serializer = require "kong.plugins.log-serializers.basic"


local kong = kong
local timer_at = ngx.timer.at


exporter.init()

local PrometheusHandler = {
  PRIORITY = 13,
  VERSION  = "0.4.1",
}


function PrometheusHandler:init_worker()
  ngx.timer.every(2, exporter.sync)
  -- TODO init shdict for each worker here
end

function PrometheusHandler:log(_)
  local message = basic_serializer.serialize(ngx)
  exporter.log(message)
end


return PrometheusHandler
