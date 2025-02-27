% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/namespace_linter.R
\name{namespace_linter}
\alias{namespace_linter}
\title{Namespace linter}
\usage{
namespace_linter(check_exports = TRUE, check_nonexports = TRUE)
}
\arguments{
\item{check_exports}{Check if \code{symbol} is exported from \code{namespace} in \code{namespace::symbol} calls.}

\item{check_nonexports}{Check if \code{symbol} exists in \code{namespace} in \code{namespace:::symbol} calls.}
}
\description{
Check for missing packages and symbols in namespace calls.
Note that using \code{check_exports=TRUE} or \code{check_nonexports=TRUE} will load packages used in user code so it could
potentially change the global state.
}
\seealso{
\link{linters} for a complete list of linters available in lintr.
}
\section{Tags}{
\link[=configurable_linters]{configurable}, \link[=correctness_linters]{correctness}, \link[=robustness_linters]{robustness}
}
