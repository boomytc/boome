//! Runtime fonts embedded with Ghostty when referenced by the code.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

/// Default fonts that we prefer for Ghostty.
pub const variable = @embedFile("jetbrains_mono_variable");
pub const variable_italic = @embedFile("jetbrains_mono_variable_italic");

/// Symbols-only nerd font.
pub const symbols_nerd_font = @embedFile("nerd_fonts_symbols_only");

/// Static JetBrains Mono faces, including the built-in Inspector font.
pub const regular = @embedFile("jetbrains_mono_regular");
pub const bold = @embedFile("jetbrains_mono_bold");
pub const italic = @embedFile("jetbrains_mono_italic");
pub const bold_italic = @embedFile("jetbrains_mono_bold_italic");

/// Emoji fonts
pub const emoji = @embedFile("res/NotoColorEmoji.ttf");
pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");
