open Utils

module T = struct
  include Tokens
end

exception LexError of string

type token_def = {
  re : Re.re;  (** The regular expression to recognize a token *)
  group : int;
      (** The match group within the regular expression that matches just the
          token itself (and not any subsequent tokens that we need to consider
          to recognize the match). In the common case where we don't need to
          look at subsequent tokens, this is group 0, which matches the whole
          regex. For constants, this is group 1. *)
  converter : string -> Tokens.t;
      (** A function to convert the matched substring into a token *)
}
(** Define how to recognize a token and convert it to a Token.t *)

type match_def = {
  matched_substring : string;
      (** Substring matching the capture group specified in token_def *)
  matching_token : token_def;  (** Which token it matched *)
}
(** A substring at the start of the input that matches a token *)

(** Functions to convert individual tokens from string to Tok.t **)

(* For tokens that match fixed strings, e.g. "{" and ";"

   Once we get a match we can just return the token without processing the
   string further. *)
let literal tok _s = tok

(* Check whether it's a keyword - otherwise it's an identifier *)
let convert_identifier = function
  | "int" -> T.KWInt
  | "return" -> T.KWReturn
  | "void" -> T.KWVoid
  | "if" -> T.KWIf
  | "else" -> T.KWElse
  | "do" -> T.KWDo
  | "while" -> T.KWWhile
  | "for" -> T.KWFor
  | "break" -> T.KWBreak
  | "continue" -> T.KWContinue
  | "static" -> T.KWStatic
  | "extern" -> T.KWExtern
  | "long" -> T.KWLong
  | "unsigned" -> T.KWUnsigned
  | "signed" -> T.KWSigned
  | "double" -> T.KWDouble
  | "char" -> T.KWChar
  | "sizeof" -> T.KWSizeOf
  | "struct" -> T.KWStruct
  | other -> T.Identifier other

let convert_int s = T.ConstInt (Z.of_string s)

let convert_long s =
  (* drop "l" suffix *)
  let const_str = StringUtil.chop_suffix s in
  T.ConstLong (Z.of_string const_str)

let convert_uint s =
  (* drop "u" suffix *)
  let const_str = StringUtil.chop_suffix s in
  T.ConstUInt (Z.of_string const_str)

let convert_ulong s =
  (* remove ul/lu suffix *)
  let const_str = StringUtil.chop_suffix ~n:2 s in
  T.ConstULong (Z.of_string const_str)

let convert_double s = T.ConstDouble (Float.of_string s)

let convert_char s =
  (* remove open and close quotes from matched input *)
  let ch = s |> StringUtil.chop_suffix |> StringUtil.drop 1 in
  T.ConstChar ch

let convert_string s =
  (* remove open and close quotes from matched input *)
  let str = s |> StringUtil.chop_suffix |> StringUtil.drop 1 in
  T.StringLiteral str

(** List of token definitions

    NOTE: we use OCaml quoted string literals like
    [{_|Here's my special string|_}], which are interpreted literally without
    escape sequences, so we can write e.g. \b instead of \\b. *)
let token_defs =
  (* Smart constructor to compile regex for token defs and use 0 as default
     group number if none is specified *)
  let def ?(group = 0) re_str converter =
    (* `ANCHORED flag means only match at start of string *)
    { re = Re.Pcre.regexp ~flags:[ `ANCHORED ] re_str; group; converter }
  in
  [
    (* all identifiers, including keywords *)
    def {_|[A-Za-z_][A-Za-z0-9_]*\b|_} convert_identifier;
    (* constants *)
    def ~group:1 {_|([0-9]+)[^\w.]|_} convert_int;
    def ~group:1 {_|([0-9]+[lL])[^\w.]|_} convert_long;
    def ~group:1 {_|([0-9]+[uU])[^\w.]|_} convert_uint;
    def ~group:1 {_|([0-9]+([lL][uU]|[uU][lL]))[^\w.]|_} convert_ulong;
    def ~group:1
      {_|(([0-9]*\.[0-9]+|[0-9]+\.?)[Ee][+-]?[0-9]+|[0-9]*\.[0-9]+|[0-9]+\.)[^\w.]|_}
      convert_double;
    def {_|'([^'\\\n]|\\['"?\\abfnrtv])'|_} convert_char;
    (* string literals *)
    def {_|"([^"\\\n]|\\['"\\?abfnrtv])*"|_} convert_string;
    (* punctuation *)
    def {_|\(|_} (literal T.OpenParen);
    def {_|\)|_} (literal T.CloseParen);
    (* NOTE: The regexes for { and } are not escaped in Table 1-1 in the book;
       but Re.Pcre requires them to be escaped. Using them unescaped to match
       literal "{" and "}" characters is legal but deprecated in Perl; see
       https://github.com/ocaml/ocaml-re/issues/200 *)
    def {_|\{|_} (literal T.OpenBrace);
    def {_|\}|_} (literal T.CloseBrace);
    def ";" (literal T.Semicolon);
    def "-" (literal T.Hyphen);
    def "--" (literal T.DoubleHyphen);
    def "~" (literal T.Tilde);
    def {_|\+|_} (literal T.Plus);
    def {_|\*|_} (literal T.Star);
    def "/" (literal T.Slash);
    def "%" (literal T.Percent);
    def "!" (literal T.Bang);
    def "&&" (literal T.LogicalAnd);
    def {_|\|\||_} (literal T.LogicalOr);
    def "==" (literal T.DoubleEqual);
    def "!=" (literal T.NotEqual);
    def "<" (literal T.LessThan);
    def ">" (literal T.GreaterThan);
    def "<=" (literal T.LessOrEqual);
    def ">=" (literal T.GreaterOrEqual);
    def "=" (literal T.EqualSign);
    def {_|\?|_} (literal T.QuestionMark);
    def ":" (literal T.Colon);
    def "," (literal T.Comma);
    def "&" (literal T.Ampersand);
    def {_|\[|_} (literal T.OpenBracket);
    def {_|\]|_} (literal T.CloseBracket);
    def "->" (literal T.Arrow);
    (* . operator must be followed by non-digit*)
    def ~group:1 {|(\.)[^\d]|} (literal T.Dot);
  ]

(** Check whether this string starts with this token; if so, return a match_def *)
let find_match s tok_def =
  let re = tok_def.re in
  let maybe_match = Re.exec_opt re s in
  match maybe_match with
  | Some m ->
      (* It matched! Now extract the matching substring. *)
      Some
        {
          matched_substring = Re.Group.get m tok_def.group;
          matching_token = tok_def;
        }
  | None -> None

(** Count number of leading whitespace characters in a string; return None if it
    doesn't start with whitespace *)
let count_leading_ws s =
  let ws_matcher = Re.Pcre.regexp ~flags:[ `ANCHORED ] {|\s+|} in
  let ws_match = Re.exec_opt ws_matcher s in
  match ws_match with
  | None -> None
  | Some mtch ->
      let _, match_end = Re.Group.offset mtch 0 in
      Some match_end

(* The main lexing function *)
let rec lex input =
  (* If input is the empty string, we're done *)
  if input = "" then []
  else
    match count_leading_ws input with
    (* If input starts with whitespace, trim it *)
    | Some ws_count -> lex (StringUtil.drop ws_count input)
    (* Otherwise, lex next token *)
    | None ->
        (* Run each regex in token_defs against start of input and return all
           matches *)
        let matches = List.filter_map (find_match input) token_defs in
        if matches = [] then raise (LexError input)
        else
          (* Find longest match*)
          let compare_match_lengths m1 m2 =
            Int.compare
              (String.length m1.matched_substring)
              (String.length m2.matched_substring)
          in
          let longest_match = ListUtil.max compare_match_lengths matches in
          (* Convert longest match to a token *)
          let converter = longest_match.matching_token.converter in
          let matching_substring = longest_match.matched_substring in
          let next_tok = converter matching_substring in
          (* Remove longest substring from input *)
          let remaining =
            StringUtil.drop
              (String.length longest_match.matched_substring)
              input
          in
          (* Lex the remainder *)
          next_tok :: lex remaining
