use once_cell::sync::Lazy;
use regex::Regex;

// Stats parsing regexes (compiled once, reused)
pub static RE_INPUT_TOKENS: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""input_tokens":(\d+)"#).unwrap());
pub static RE_OUTPUT_TOKENS: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""output_tokens":(\d+)"#).unwrap());
pub static RE_CACHE_READ: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""cache_read_input_tokens":(\d+)"#).unwrap());
pub static RE_CACHE_CREATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""cache_creation_input_tokens":(\d+)"#).unwrap());
pub static RE_MODEL: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""model":"claude-([^"]+)"#).unwrap());
pub static RE_SUMMARY: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""type":"summary","summary":"([^"]+)""#).unwrap());
pub static RE_TIMESTAMP: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#""timestamp":"(\d{4}-\d{2}-\d{2}T[^"]+)""#).unwrap());

// Frontmatter parsing regexes
pub static RE_FRONTMATTER: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)^---\s*\n(.*?)\n---").unwrap());
pub static RE_FRONTMATTER_NAME: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^name:\s*(.+)$").unwrap());
pub static RE_FRONTMATTER_DESC: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^description:\s*(.+)$").unwrap());

// Markdown stripping regexes
pub static RE_MD_BOLD_ASTERISK: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\*\*([^*]+)\*\*").unwrap());
pub static RE_MD_ITALIC_ASTERISK: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\*([^*]+)\*").unwrap());
pub static RE_MD_BOLD_UNDERSCORE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"__([^_]+)__").unwrap());
pub static RE_MD_ITALIC_UNDERSCORE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"_([^_]+)_").unwrap());
pub static RE_MD_CODE: Lazy<Regex> = Lazy::new(|| Regex::new(r"`([^`]+)`").unwrap());
pub static RE_MD_HEADING: Lazy<Regex> = Lazy::new(|| Regex::new(r"^#+\s*").unwrap());
pub static RE_MD_LINK: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[([^\]]+)\]\([^)]+\)").unwrap());
