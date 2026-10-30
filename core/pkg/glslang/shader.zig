const std = @import("std");
const c = @import("c.zig").c;

pub const Shader = opaque {
    pub fn create(input: *const c.glslang_input_t) !*Shader {
        if (c.glslang_shader_create(input)) |ptr| return @ptrCast(ptr);
        return error.OutOfMemory;
    }

    pub fn delete(self: *Shader) void {
        c.glslang_shader_delete(@ptrCast(self));
    }

    pub fn preprocess(self: *Shader, input: *const c.glslang_input_t) !void {
        if (c.glslang_shader_preprocess(@ptrCast(self), input) == 0)
            return error.GlslangFailed;
    }

    pub fn parse(self: *Shader, input: *const c.glslang_input_t) !void {
        if (c.glslang_shader_parse(@ptrCast(self), input) == 0)
            return error.GlslangFailed;
    }

    pub fn getInfoLog(self: *Shader) ![:0]const u8 {
        const ptr = c.glslang_shader_get_info_log(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn getDebugInfoLog(self: *Shader) ![:0]const u8 {
        const ptr = c.glslang_shader_get_info_debug_log(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }
};
