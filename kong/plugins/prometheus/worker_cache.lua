local cache = {}
local hash_label_mapping = {}


-- TODO cache layer per work, sync up with shdict periodically
--
function inc(name, value, label_values)
    local metric = cache[name]
    local hash_key = table.concat(label_values, "*")
    if metric[hash_key] == nil then
        kong.log.err(name, "is nil")
        hash_label_mapping[hash_key] = label_values
        metric[hash_key] = value
    else
        metric[hash_key] =  metric[hash_key] + value
    end
end

function observe(name, value, label_values)
-- TODO
end

return {
    cache = cache,
    hash_label_mapping = hash_label_mapping,
    inc = inc,
    observe = observe,
}
