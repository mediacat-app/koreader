local logger = require("logger")
local time = require("ui/time")
local url = require("socket.url")

local OPDSPerf = {}

function OPDSPerf.start()
    return time.now()
end

function OPDSPerf.elapsedMs(start_time)
    return time.to_s(time.since(start_time)) * 1000
end

function OPDSPerf.endpoint(raw_url)
    if not raw_url then
        return "<nil>"
    end

    local parsed = url.parse(raw_url)
    if not parsed then
        return "<invalid-url>"
    end

    local path = parsed.path or "/"
    -- Catalog URLs can contain opaque IDs (and sometimes API keys) in the path.
    path = path:gsub("([^/]+)", function(component)
        return #component >= 24 and "<redacted>" or component
    end)

    return string.format("%s://%s%s%s", parsed.scheme or "?", parsed.host or "?",
        parsed.port and ":" .. parsed.port or "", path)
end

function OPDSPerf.log(format, ...)
    logger.info("OPDS perf: " .. string.format(format, ...))
end

return OPDSPerf
