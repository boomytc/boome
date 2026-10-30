/// SurfaceMouse represents mouse helper functionality for the core surface.
///
/// It's currently small in scope; its purpose is to isolate mouse logic that
/// has gotten a bit complex (e.g. pointer shape handling for key events), but
/// the intention is to grow it later so that we can better test said logic).
const SurfaceMouse = @This();

const builtin = @import("builtin");
const input = @import("input.zig");
const terminal = @import("terminal/main.zig");
const MouseShape = @import("terminal/mouse_shape.zig").MouseShape;

/// For processing key events; the key that was physically pressed on the
/// keyboard.
physical_key: input.Key,

/// The mouse event tracking mode, if any.
mouse_event: terminal.Terminal.MouseEvents,

/// The current terminal's mouse shape.
mouse_shape: MouseShape,

/// The last mods state when the last mouse button (whatever it was) was
/// pressed or release.
mods: input.Mods,

/// True if the mouse position is currently over a link.
over_link: bool,

/// True if the mouse pointer is currently hidden.
hidden: bool,

/// Translates key state to mouse shape (cursor) state, based on a state
/// machine.
///
/// There are 4 current states:
///
/// * text: starting state, displays a text bar.
/// * default: default state when in a mouse tracking mode. (e.g. vim, etc).
///   Displays an arrow pointer.
/// * pointer: default state when over a link. Displays a pointing finger.
/// * crosshair: any above state can transition to this when the rectangle
///   select keys are pressed (ctrl/super+alt).
///
/// Additionally, default can transition back to text if one of the shift keys
/// are pressed during mouse tracking mode.
///
/// Any secondary state transitions back to its default state when the
/// appropriate keys are released.
///
/// null is returned when the mouse shape does not need changing.
pub fn keyToMouseShape(self: SurfaceMouse) ?MouseShape {
    // Filter for appropriate key events
    if (!eligibleMouseShapeKeyEvent(self.physical_key)) return null;

    // Exceptions: link hover or hidden state overrides any other shape
    // processing and does not change state.
    //
    // TODO: As we unravel mouse state, we can fix this to be more explicit.
    if (self.over_link or self.hidden) {
        return null;
    }

    // Set our current default state
    var current_shape_state: MouseShape = undefined;
    if (self.mouse_event != .none) {
        // In mouse tracking mode, should be default (arrow pointer)
        current_shape_state = .default;
    } else {
        // Default terminal mode, should be text (text bar)
        current_shape_state = .text;
    }

    // Transition table.
    //
    // TODO: This could be updated eventually to be a true transition table if
    // we move to a full stateful mouse surface, e.g. very specific inputs
    // transitioning state based on previous state, versus flags like "is the
    // mouse over a link", etc.
    switch (current_shape_state) {
        .default => {
            if (isMouseModeOverrideState(self.mods) and isRectangleSelectState(self.mods)) {
                // Crosshair (rectangle select), only set if we are also
                // overriding (e.g. shift+ctrl+alt)
                return .crosshair;
            } else if (isMouseModeOverrideState(self.mods)) {
                // Normal override state
                return .text;
            } else {
                return .default;
            }
        },

        .text => {
            if (isRectangleSelectState(self.mods)) {
                // Crosshair (rectangle select)
                return .crosshair;
            } else {
                return .text;
            }
        },

        // Fall back on default state
        else => unreachable,
    }
}

fn eligibleMouseShapeKeyEvent(physical_key: input.Key) bool {
    return physical_key.ctrlOrSuper() or
        physical_key.leftOrRightShift() or
        physical_key.leftOrRightAlt();
}

fn isMouseModeOverrideState(mods: input.Mods) bool {
    return mods.shift;
}

/// Returns true if our modifiers put us in a state where dragging
/// should cause a rectangle select.
pub fn isRectangleSelectState(mods: input.Mods) bool {
    return if (comptime builtin.target.os.tag.isDarwin())
        mods.alt
    else
        mods.ctrlOrSuper() and mods.alt;
}
