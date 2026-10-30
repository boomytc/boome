const options = @import("build_options");

// vt.cpp
extern "c" fn ghostty_simd_codepoint_width(u32) i8;

pub fn codepointWidth(cp: u32) i8 {
    if (comptime options.simd) return ghostty_simd_codepoint_width(cp);
    const uucode = @import("uucode");
    if (cp > uucode.config.max_code_point) return 1;
    return @import("uucode").get(.width, @intCast(cp));
}
