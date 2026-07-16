# Central HTTP layer for the toolkit's outbound requests.

# Hosts that serve an anti-crawler challenge to nu's default User-Agent.
const CHALLENGE_HOSTS = ["autopkgtest.ubuntu.com"]

# The cookie header that satisfies the challenge for CHALLENGE_HOSTS, or an
# empty record for hosts that don't challenge (where it would be dead weight).
def challenge-headers [url: string]: nothing -> record {
    let host = ($url | url parse | get host)
    if $host in $CHALLENGE_HOSTS { { Cookie: "not_a_crawler=1" } } else { {} }
}

# Wrap http get with the challenge cookie for hosts that require it.
# Returns the body on 2XX, null on 404, and explicitly errors on everything else, with an explicit message for 429.
# --raw passes through to underlying http get
export def http-get [
    url: string
    --raw                     # return the unparsed body (for binary/decompression callers)
    --headers: record = {}    # extra request headers, merged over the challenge cookie
]: nothing -> any {
    let hdrs = ((challenge-headers $url) | merge $headers)
    let resp = if $raw {
        http get --full --allow-errors --raw --headers $hdrs $url
    } else {
        http get --full --allow-errors --headers $hdrs $url
    }
    match $resp.status {
        200..299 => $resp.body
        404 => null
        429 => (error make { msg: $"HTTP 429 fetching ($url): rate-limited or anti-crawler challenge not satisfied" })
        _ => (error make { msg: $"HTTP ($resp.status) fetching ($url)" })
    }
}

# Wrap http post with the same error policy as http-get.
# Returns the body on 2XX, null on 404, and explicitly errors on everything else.
# --headers: extra request headers (e.g. {PRIVATE-TOKEN: $token}).
# --data: the request body (string or binary). Defaults to empty string.
export def http-post [
    url: string
    --data: any = ""          # request body
    --headers: record = {}    # extra request headers
]: nothing -> any {
    let resp = (http post --full --allow-errors --headers $headers $url $data)
    match $resp.status {
        200..299 => $resp.body
        404 => null
        429 => (error make { msg: $"HTTP 429 posting to ($url): rate-limited" })
        _ => (error make { msg: $"HTTP ($resp.status) posting to ($url)" })
    }
}
