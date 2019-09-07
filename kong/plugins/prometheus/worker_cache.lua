local cache = {}


-- TODO cache layer per work, sync up with shdict periodically
--
function inc(name, value, label_values)
    local metric = cache[name]
    if metric[label_values] == nil then
        kong.log.err(name, "is nil")
        metric[label_values] = value
    else
        metric[label_values] =  metric[label_values] + value
    end
end

function observe(name, value, label_values)
-- TODO
end

return {
    cache = cache,
    inc = inc,
    observe = observe,
}
