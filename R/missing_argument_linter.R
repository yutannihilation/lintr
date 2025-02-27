#' Missing argument linter
#'
#' Check for missing arguments in function calls.
#' @param except a character vector of function names as exceptions.
#' @evalRd rd_tags("missing_argument_linter")
#' @seealso [linters] for a complete list of linters available in lintr.
#' @export
missing_argument_linter <- function(except = c("switch", "alist")) {
  xpath <- "//expr[expr[SYMBOL_FUNCTION_CALL]]/*[
    self::OP-COMMA[preceding-sibling::*[not(self::COMMENT)][1][self::OP-LEFT-PAREN or self::OP-COMMA]] or
    self::OP-COMMA[following-sibling::*[not(self::COMMENT)][1][self::OP-RIGHT-PAREN]] or
    self::EQ_SUB[following-sibling::*[not(self::COMMENT)][1][self::OP-RIGHT-PAREN or self::OP-COMMA]]
  ]"
  to_function_xpath <- "string(./preceding-sibling::expr/SYMBOL_FUNCTION_CALL)"

  Linter(function(source_expression) {
    if (!is_lint_level(source_expression, "file")) {
      return(list())
    }

    xml <- source_expression$full_xml_parsed_content

    missing_args <- xml2::xml_find_all(xml, xpath)
    function_call_name <- get_r_string(xml2::xml_find_chr(missing_args, to_function_xpath))

    xml_nodes_to_lints(
      missing_args[!function_call_name %in% except],
      source_expression = source_expression,
      lint_message = "Missing argument in function call."
    )
  })
}
