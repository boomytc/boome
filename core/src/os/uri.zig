const std = @import("std");

pub const ParseOptions = struct {
    /// Parse MAC addresses in the host component.
    ///
    /// This is useful when the "Private Wi-Fi address" is enabled on macOS,
    /// which sets the hostname to a rotating MAC address (12:34:56:ab:cd:ef).
    mac_address: bool = false,

    /// Return the full, raw, unencoded path string. Any query and fragment
    /// values will be return as part of the path instead of as distinct
    /// fields.
    raw_path: bool = false,
};

pub const ParseError = std.Uri.ParseError || error{InvalidMacAddress};

/// Parses a URI from the given string.
///
/// This extends std.Uri.parse with some additional ParseOptions.
pub fn parse(text: []const u8, options: ParseOptions) ParseError!std.Uri {
    var uri = std.Uri.parse(text) catch |err| uri: {
        // We can attempt to re-parse the text as a URI that has a MAC address
        // in its host field (which tripped up std.Uri.parse's port parsing):
        //
        //      file://12:34:56:78:90:aa/path/to/file
        //                            ^^ InvalidPort
        //
        if (err != error.InvalidPort or !options.mac_address) return err;

        // We can assume that the initial Uri.parse already validated the
        // scheme, so we only need to find its bounds within the string.
        const scheme_end = std.mem.indexOf(u8, text, "://") orelse {
            return error.InvalidFormat;
        };
        const scheme = text[0..scheme_end];

        // We similarly find the bounds of the host component by looking
        // for the first slash (/) after the scheme. This is all we need
        // for this case because the resulting slice can be unambiguously
        // determined to be a MAC address (or not).
        const host_start = scheme_end + "://".len;
        const host_end = std.mem.indexOfScalarPos(u8, text, host_start, '/') orelse text.len;
        const mac_address = text[host_start..host_end];
        if (!isValidMacAddress(mac_address)) return error.InvalidMacAddress;

        // Parse the rest of the text (starting with the path component) as a
        // partial URI and then add our MAC address as its host component.
        var uri = try std.Uri.parseAfterScheme(scheme, text[host_end..]);
        uri.host = .{ .percent_encoded = mac_address };
        break :uri uri;
    };

    // When MAC address parsing is enabled, we need to handle the case where
    // std.Uri.parse parsed the address's last octet as a numeric port number.
    // We use a few heuristics to identify this case (14 characters, 4 colons)
    // and then "repair" the result by reassign the .host component to the full
    // MAC address and clearing the .port component.
    //
    //    12:34:56:78:90:99 -> [12:34:56:78:90, 99] -> 12:34:56:78:90:99
    //    (original host)      (parsed host + port)    (restored host)
    //
    if (options.mac_address and uri.host != null) mac: {
        const host = uri.host.?.percent_encoded;
        if (host.len != 14 or std.mem.count(u8, host, ":") != 4) break :mac;

        const port = uri.port orelse break :mac;
        if (port > 99) break :mac;

        // std.Uri.parse returns slices pointing into the original text string.
        const host_start = @intFromPtr(host.ptr) - @intFromPtr(text.ptr);
        const path_start = @intFromPtr(uri.path.percent_encoded.ptr) - @intFromPtr(text.ptr);
        const mac_address = text[host_start..path_start];
        if (!isValidMacAddress(mac_address)) return error.InvalidMacAddress;

        uri.host = .{ .percent_encoded = mac_address };
        uri.port = null;
    }

    // When the raw_path option is active, return everything after the authority
    // (host) in the .path component, including any query and fragment values.
    if (options.raw_path) {
        // std.Uri.parse returns slices pointing into the original text string.
        const path_start = @intFromPtr(uri.path.percent_encoded.ptr) - @intFromPtr(text.ptr);
        uri.path = .{ .raw = text[path_start..] };
        uri.query = null;
        uri.fragment = null;
    }

    return uri;
}

/// Checks if a string represents a valid MAC address, e.g. 12:34:56:ab:cd:ef.
fn isValidMacAddress(s: []const u8) bool {
    if (s.len != 17) return false;

    for (s, 0..) |c, i| {
        if (i % 3 == 2) {
            if (c != ':') return false;
        } else {
            switch (c) {
                '0'...'9', 'A'...'F', 'a'...'f' => {},
                else => return false,
            }
        }
    }

    return true;
}
