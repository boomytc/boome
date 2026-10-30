/// Default URL/path regex. This is used to detect URLs and file paths in
/// terminal output.
///
/// This is here in the config package because one day the matchers will be
/// configurable and this will be a default.
///
/// For scheme URLs, this regex is liberal in what it accepts after the scheme,
/// with exceptions for URLs ending with . or ). Although such URLs are
/// perfectly valid, it is common for text to contain URLs surrounded by
/// parentheses (such as in Markdown links) or at the end of sentences.
/// Therefore, this regex excludes them as follows:
///
/// 1. Do not match regexes ending with .
/// 2. Do not match regexes ending with ), except for ones which contain a (
///    without a subsequent )
///
/// Rule 2 means that that we handle the following two cases:
///
///   "https://en.wikipedia.org/wiki/Rust_(video_game)" (include parens)
///   "(https://example.com)" (do not include the parens)
///
/// There are many complicated cases where these heuristics break down, but
/// handling them well requires a non-regex approach.
const url_schemes =
    \\https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:
;

const ipv6_url_pattern =
    \\(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)
;

const scheme_url_chars =
    \\[\w\-.~:/?#@!$&*+,;=%]
;

const path_chars =
    \\[\w\-.~:\/?#@!$&*+;=%]
;

const optional_bracketed_word_suffix =
    \\(?:[\(\[]\w*[\)\]])?
;

const no_trailing_punctuation =
    \\(?<![,.])
;

const no_trailing_colon =
    \\(?<!:)
;

const trailing_spaces_at_eol =
    \\(?: +(?= *$))?
;

const dotted_path_lookahead =
    \\(?=[\w\-.~:\/?#@!$&*+;=%]*\.)
;

const non_dotted_path_lookahead =
    \\(?![\w\-.~:\/?#@!$&*+;=%]*\.)
;

const dotted_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*
;

const any_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]+)*
;

// Branch 1: URLs with explicit schemes (http, mailto, ftp, etc.).
const scheme_url_branch =
    "(?:" ++ url_schemes ++ ")" ++
    "(?:" ++ ipv6_url_pattern ++ "|" ++ scheme_url_chars ++ "+" ++ optional_bracketed_word_suffix ++ ")+" ++
    no_trailing_punctuation;

const rooted_or_relative_path_prefix =
    \\(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))
;

// Branch 2: Absolute paths and dot-relative paths (/, ./, ../).
// A dotted segment is treated as file-like, while the undotted case stays
// broad to capture directory-like paths with spaces.
const rooted_or_relative_path_branch =
    rooted_or_relative_path_prefix ++
    "(?:" ++
    dotted_path_lookahead ++
    path_chars ++ "+" ++
    dotted_path_space_segments ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    "|" ++
    non_dotted_path_lookahead ++
    path_chars ++ "+" ++
    any_path_space_segments ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    ")";

// Branch 3: Bare relative paths such as src/config/url.zig.
const bare_relative_path_prefix =
    \\(?<!\$\d*)(?<!\w)[\w][\w\-.]*\/
;

const bare_relative_path_branch =
    dotted_path_lookahead ++
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_colon ++
    trailing_spaces_at_eol;

pub const regex =
    scheme_url_branch ++
    "|" ++
    rooted_or_relative_path_branch ++
    "|" ++
    bare_relative_path_branch;
