//! This module provides a low level http interface for working with AWS
//! It also provides an option to operate outside the AWS ecosystem through
//! the makeRequest call with a null signingOptions.
//!
//! Typical usage:
//! const client = awshttp.AwsHttp.init(allocator);
//! defer client.deinit()
//! const result = client.callApi (or client.makeRequest)
//! defer result.deinit();
const std = @import("std");
const base = @import("aws_http_base.zig");
const signing = @import("aws_signing.zig");
const credentials = @import("aws_credentials.zig");
const zfetch = @import("zfetch");
const tls = @import("iguanaTLS");

const CN_NORTH_1_HASH = std.hash_map.hashString("cn-north-1");
const CN_NORTHWEST_1_HASH = std.hash_map.hashString("cn-northwest-1");
const US_ISO_EAST_1_HASH = std.hash_map.hashString("us-iso-east-1");
const US_ISOB_EAST_1_HASH = std.hash_map.hashString("us-isob-east-1");

const log = std.log.scoped(.awshttp);

const amazon_root_ca_1 = @embedFile("../Amazon_Root_CA_1.pem");

pub const default_root_ca = amazon_root_ca_1;

pub const AwsError = error{
    AddHeaderError,
    AlpnError,
    CredentialsError,
    HttpClientConnectError,
    HttpRequestError,
    SignableError,
    SigningInitiationError,
    TlsError,
    RequestCreateError,
    SetupConnectionError,
    StatusCodeError,
    SetRequestMethodError,
    SetRequestPathError,
};

pub const Options = struct {
    region: []const u8 = "aws-global",
    dualstack: bool = false,
    sigv4_service_name: ?[]const u8 = null,
};

pub const Header = base.Header;
pub const HttpRequest = base.Request;
pub const HttpResult = base.Result;

const EndPoint = struct {
    uri: []const u8,
    host: []const u8,
    scheme: []const u8,
    port: u16,
    allocator: std.mem.Allocator,

    fn deinit(self: EndPoint) void {
        self.allocator.free(self.uri);
    }
};
pub const AwsHttp = struct {
    allocator: std.mem.Allocator,
    trust_chain: ?tls.x509.CertificateChain,

    const Self = @This();

    /// Recommend usage is init(allocator, awshttp.default_root_ca)
    /// Passing null for root_pem will result in no TLS verification
    pub fn init(allocator: std.mem.Allocator, root_pem: ?[]const u8) !Self {
        var trust_chain: ?tls.x509.CertificateChain = null;
        if (root_pem) |p| {
            var fbs = std.io.fixedBufferStream(p);
            trust_chain = try tls.x509.CertificateChain.from_pem(allocator, fbs.reader());
        }
        return Self{
            .allocator = allocator,
            .trust_chain = trust_chain,
            // .credentialsProvider = // creds provider could be useful
        };
    }

    pub fn deinit(self: *AwsHttp) void {
        if (self.trust_chain) |c| c.deinit();
        _ = self;
        log.debug("Deinit complete", .{});
    }

    /// callApi allows the calling of AWS APIs through a higher-level interface.
    /// It will calculate the appropriate endpoint and action parameters for the
    /// service called, and will set up the signing options. The return
    /// value is simply a raw HttpResult
    pub fn callApi(self: Self, service: []const u8, request: HttpRequest, options: Options) !HttpResult {
        const endpoint = try regionSubDomain(self.allocator, service, options.region, options.dualstack);
        defer endpoint.deinit();
        log.debug("Calling endpoint {s}", .{endpoint.uri});
        const creds = try credentials.getCredentials(self.allocator);
        // defer allocator.free(), except sometimes we don't need freeing...
        const signing_config: signing.Config = .{
            .region = options.region,
            .service = options.sigv4_service_name orelse service,
            .credentials = creds,
        };
        return try self.makeRequest(endpoint, request, signing_config);
    }

    /// makeRequest is a low level http/https function that can be used inside
    /// or outside the context of AWS services. To use it outside AWS, simply
    /// pass a null value in for signing_options.
    ///
    /// Otherwise, it will simply take a URL endpoint (without path information),
    /// HTTP method (e.g. GET, POST, etc.), and request body.
    ///
    /// At the moment this does not allow changing headers, but addtional
    /// ones are possible. This is likely to change. Current headers are:
    ///
    /// Accept: application/json
    /// User-Agent: zig-aws 1.0, Powered by the AWS Common Runtime.
    /// Content-Type: application/x-www-form-urlencoded
    /// Content-Length: (length of body)
    ///
    /// Return value is an HttpResult, which will need the caller to deinit().
    pub fn makeRequest(self: Self, endpoint: EndPoint, request: HttpRequest, signing_config: ?signing.Config) !HttpResult {
        var request_cp = request;

        log.debug("Path: {s}", .{request_cp.path});
        log.debug("Query: {s}", .{request_cp.query});
        log.debug("Method: {s}", .{request_cp.method});
        log.debug("body length: {d}", .{request_cp.body.len});
        log.debug("Body\n====\n{s}\n====", .{request_cp.body});

        var request_headers = std.ArrayList(base.Header).init(self.allocator);
        defer request_headers.deinit();

        const len = try addHeaders(self.allocator, &request_headers, endpoint.host, request_cp.body, request_cp.content_type, request_cp.headers);
        defer if (len) |l| self.allocator.free(l);
        request_cp.headers = request_headers.items;

        if (signing_config) |opts| request_cp = try signing.signRequest(self.allocator, request_cp, opts);
        defer {
            if (signing_config) |opts| {
                signing.freeSignedRequest(self.allocator, &request_cp, opts);
            }
        }

        try zfetch.init(); // This only does anything on Windows. Not sure how performant it is to do this on every request
        defer zfetch.deinit();
        var headers = zfetch.Headers.init(self.allocator);
        defer headers.deinit();
        for (request_cp.headers) |header|
            try headers.appendValue(header.name, header.value);
        log.debug("All Request Headers (zfetch):", .{});
        for (headers.list.items) |h| {
            log.debug("\t{s}: {s}", .{ h.name, h.value });
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ endpoint.uri, request.path, request.query });
        defer self.allocator.free(url);
        log.debug("Request url: {s}", .{url});
        var req = try zfetch.Request.init(self.allocator, url, self.trust_chain);
        defer req.deinit();

        const method = std.meta.stringToEnum(zfetch.Method, request_cp.method).?;
        try req.do(method, headers, if (request_cp.body.len == 0) null else request_cp.body);

        // TODO: Timeout - is this now above us?
        log.debug("request_complete. Response code {d}: {s}", .{ req.status.code, req.status.reason });
        log.debug("Response headers:", .{});
        var resp_headers = try std.ArrayList(Header).initCapacity(self.allocator, req.headers.list.items.len);
        defer resp_headers.deinit();
        var content_length: usize = 0;
        for (req.headers.list.items) |h| {
            log.debug("    {s}: {s}", .{ h.name, h.value });
            resp_headers.appendAssumeCapacity(.{
                .name = try (self.allocator.dupe(u8, h.name)),
                .value = try (self.allocator.dupe(u8, h.value)),
            });
            if (content_length == 0 and std.ascii.eqlIgnoreCase("content-length", h.name))
                content_length = std.fmt.parseInt(usize, h.value, 10) catch 0;
        }
        const reader = req.reader();
        var buf: [65535]u8 = undefined;
        var resp_payload = try std.ArrayList(u8).initCapacity(self.allocator, content_length);
        defer resp_payload.deinit();

        while (true) {
            const read = try reader.read(&buf);
            try resp_payload.appendSlice(buf[0..read]);
            if (read == 0) break;
        }
        log.debug("raw response body:\n{s}", .{resp_payload.items});

        const rc = HttpResult{
            .response_code = req.status.code,
            .body = resp_payload.toOwnedSlice(),
            .headers = resp_headers.toOwnedSlice(),
            .allocator = self.allocator,
        };
        return rc;
    }
};

fn addHeaders(allocator: std.mem.Allocator, headers: *std.ArrayList(base.Header), host: []const u8, body: []const u8, content_type: []const u8, additional_headers: []Header) !?[]const u8 {
    try headers.append(.{ .name = "Accept", .value = "application/json" });
    try headers.append(.{ .name = "Host", .value = host });
    try headers.append(.{ .name = "User-Agent", .value = "zig-aws 1.0, Powered by the AWS Common Runtime." });
    try headers.append(.{ .name = "Content-Type", .value = content_type });
    try headers.appendSlice(additional_headers);
    if (body.len > 0) {
        const len = try std.fmt.allocPrint(allocator, "{d}", .{body.len});
        try headers.append(.{ .name = "Content-Length", .value = len });
        return len;
    }
    return null;
}

fn regionSubDomain(allocator: std.mem.Allocator, service: []const u8, region: []const u8, useDualStack: bool) !EndPoint {
    const environment_override = std.os.getenv("AWS_ENDPOINT_URL");
    if (environment_override) |override| {
        const uri = try allocator.dupeZ(u8, override);
        return endPointFromUri(allocator, uri);
    }
    // Fallback to us-east-1 if global endpoint does not exist.
    const realregion = if (std.mem.eql(u8, region, "aws-global")) "us-east-1" else region;
    const dualstack = if (useDualStack) ".dualstack" else "";

    const domain = switch (std.hash_map.hashString(region)) {
        US_ISO_EAST_1_HASH => "c2s.ic.gov",
        CN_NORTH_1_HASH, CN_NORTHWEST_1_HASH => "amazonaws.com.cn",
        US_ISOB_EAST_1_HASH => "sc2s.sgov.gov",
        else => "amazonaws.com",
    };

    const uri = try std.fmt.allocPrintZ(allocator, "https://{s}{s}.{s}.{s}", .{ service, dualstack, realregion, domain });
    const host = uri["https://".len..];
    log.debug("host: {s}, scheme: {s}, port: {}", .{ host, "https", 443 });
    return EndPoint{
        .uri = uri,
        .host = host,
        .scheme = "https",
        .port = 443,
        .allocator = allocator,
    };
}

/// creates an endpoint from a uri string.
///
/// allocator: Will be used only to construct the EndPoint struct
/// uri: string constructed in such a way that deallocation is needed
fn endPointFromUri(allocator: std.mem.Allocator, uri: []const u8) !EndPoint {
    var scheme: []const u8 = "";
    var host: []const u8 = "";
    var port: u16 = 443;
    var host_start: usize = 0;
    var host_end: usize = 0;
    for (uri) |ch, i| {
        switch (ch) {
            ':' => {
                if (!std.mem.eql(u8, scheme, "")) {
                    // here to end is port - this is likely a bug if ipv6 address used
                    const rest_of_uri = uri[i + 1 ..];
                    port = try std.fmt.parseUnsigned(u16, rest_of_uri, 10);
                    host_end = i;
                }
            },
            '/' => {
                if (host_start == 0) {
                    host_start = i + 2;
                    scheme = uri[0 .. i - 1];
                    if (std.mem.eql(u8, scheme, "http")) {
                        port = 80;
                    } else {
                        port = 443;
                    }
                }
            },
            else => continue,
        }
    }
    if (host_end == 0) {
        host_end = uri.len;
    }
    host = uri[host_start..host_end];

    log.debug("host: {s}, scheme: {s}, port: {}", .{ host, scheme, port });
    return EndPoint{
        .uri = uri,
        .host = host,
        .scheme = scheme,
        .allocator = allocator,
        .port = port,
    };
}
