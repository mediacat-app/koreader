local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local OPDSPerf = require("opdsperf")

local OPDSClient = {}
OPDSClient.__index = OPDSClient

local redirect_codes = {
    [301] = true,
    [302] = true,
    [303] = true,
    [307] = true,
    [308] = true,
}

local default_ports = {
    http = 80,
    https = 443,
}

local function isIdempotentRequest(method)
    return method == nil or method == "GET" or method == "HEAD"
end

local function isSameOrigin(left, right)
    return left.scheme == right.scheme
        and left.host == right.host
        and (left.port or default_ports[left.scheme]) == (right.port or default_ports[right.scheme])
end

local function isHttpsDowngrade(from_url, to_url)
    return url.parse(from_url).scheme == "https" and url.parse(to_url).scheme == "http"
end

function OPDSClient:new(options)
    return setmetatable(options, self)
end

function OPDSClient:request(request)
    local request_url = request.url
    local original_headers = request.headers or {}
    local original_origin = url.parse(request_url)
    local attempt_number = 0

    for _ = 1, 5 do
        local headers = {}
        for name, value in pairs(original_headers) do
            if name:lower() ~= "cookie" then headers[name] = value end
        end
        local cookies = self.cookie_jar:headerFor(request_url)
        if cookies then headers.Cookie = cookies end

        local request_origin = url.parse(request_url)
        local same_origin = isSameOrigin(request_origin, original_origin)
        local function makeRequest()
            return socket.skip(1, http.request {
                url = request_url,
                method = request.method,
                headers = headers,
                sink = request.sink,
                user = same_origin and request.username or nil,
                password = same_origin and request.password or nil,
                redirect = false,
                response_headers = function(response_code)
                    return redirect_codes[response_code]
                end,
            })
        end

        attempt_number = attempt_number + 1
        local attempt_started = OPDSPerf.start()
        local code, response_headers, status = makeRequest()
        OPDSPerf.log("http_attempt attempt=%d endpoint=%s status=%s redirect=%s request_ms=%.3f",
            attempt_number, OPDSPerf.endpoint(request_url), tostring(code or status),
            tostring(redirect_codes[code] and response_headers and response_headers.location ~= nil),
            OPDSPerf.elapsedMs(attempt_started))
        if code == socketutil.SSL_HANDSHAKE_CODE and isIdempotentRequest(request.method) then
            attempt_number = attempt_number + 1
            attempt_started = OPDSPerf.start()
            code, response_headers, status = makeRequest()
            OPDSPerf.log("http_attempt attempt=%d endpoint=%s status=%s redirect=%s request_ms=%.3f retry=tls",
                attempt_number, OPDSPerf.endpoint(request_url), tostring(code or status),
                tostring(redirect_codes[code] and response_headers and response_headers.location ~= nil),
                OPDSPerf.elapsedMs(attempt_started))
        end
        self.cookie_jar:store(request_url, response_headers)

        if not redirect_codes[code] or not response_headers or not response_headers.location then
            return code, response_headers, status
        end

        local redirected_url = url.absolute(request_url, response_headers.location)
        if isHttpsDowngrade(request_url, redirected_url) then
            return code, response_headers, status
        end
        request_url = redirected_url
    end

    return nil, nil, "Too many redirects"
end

return OPDSClient
