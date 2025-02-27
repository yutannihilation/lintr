#!/usr/local/bin/Rscript

# compare the lints obtained before/after a given PR/branch vs a base branch (default master).
#
# How to use:
#   See below (param_list <-) for documentation of the script's arguments.
#   Most importantly, you'll need to provide a `--pkg_dir` pointing to a
#     local directory containing R packages, e.g., a CRAN mirror or GitHub
#     directory containing some number of packages. For a CRAN mirror at $CRAN_MIRROR,
#     the correct subdirectory to use is $CRAN_MIRROR/src/contrib, which contains the R
#     source code (the other binary directories only contain R code in inst/).
#   The script is executable, e.g. you can run the following from the lintr TLD:
#     ./dev/compare_branches --pkg_dir=/path/to/cran --sample_size=50 ...
#   The script outputs a CSV with the lint results for the script options to --outfile.
#   To compare the results of a PR to that at current HEAD, you could e.g. run
#     ./dev/compare_branches --branch=my-feature-branch ...
#   And then compare the results found in the new CSV file in .dev

# TODO
#  - make sure this works for comparing tags to facilitate release testing
#  - handle the case when working directory is not the lintr directory
#  - support an interface for ad hoc download of packages to support running
#    the script without needing a CRAN mirror more easily/friendly

# TODO
#  - make sure this works for comparing tags to facilitate release testing
#  - handle the case when working directory is not the lintr directory

suppressPackageStartupMessages({
  library(optparse)
  library(data.table, include.only = "fwrite")
  library(dplyr)
  library(purrr)
  library(tibble)
  library(usethis)
  library(gert)
  library(pkgload)
})

if (!file.exists("lintr.Rproj")) {
  stop("compare_branches.R should be run inside the lintr-package directory")
}

# move to temp repo. this allows multiple executions of this
#   script simultaneously (otherwise the branch state across
#   executions will collide), as well as continuing dev
#   on the "main" package clone while the script runs (otherwise
#   all current edits must be checked in before running)
# named lintr_repo in case this script happens to be run against
#   a tar of lintr itself...
temp_repo <- file.path(tempdir(), "lintr_repo")
dir.create(temp_repo)
invisible(file.copy(".", temp_repo, recursive = TRUE))
message("Executing from copy of repo at ", temp_repo)
old_wd <- setwd(temp_repo)
if (!interactive()) {
  .Last <- function() {
    setwd(old_wd)
    unlink(temp_repo, recursive = TRUE)
  }
}

param_list <- list(
  optparse::make_option(
    "--linters",
    default = if (interactive()) {
      readline("Provide a comma-separated list of linters to compare: ")
    },
    help = "Run the comparison for these linter(s) (comma-separated)"
  ),
  optparse::make_option(
    "--base_branch",
    default = if (interactive()) {
      readline("Name a branch to use as base (skip to use master): ")
    } else {
      "master"
    },
    help = "Compare to this branch"
  ),
  optparse::make_option(
    "--branch",
    default = if (interactive()) {
      readline("Name a branch to compare to the base branch (or skip to enter a PR# or to run only on base_branch): ")
    },
    help = "Run the comparison for base vs. this branch"
  ),
  optparse::make_option(
    "--pr",
    default = if (interactive()) {
      # NB: optparse handles integer conversion
      readline("Name a PR # to compare to the base branch (skip if you've entered a branch or to run only on base_branch): ")
    },
    type = "integer",
    help = "Run the comparison for base vs. this PR"
  ),
  optparse::make_option(
    "--pkg_dir",
    default = if (nzchar(cran_mirror <- Sys.getenv("CRAN_MIRROR"))) {
      dir <- file.path(cran_mirror, "src", "contrib")
      message("Using the CRAN miror found at Sys.getenv('CRAN_MIRROR'): ", dir)
      dir
    } else if (interactive()) {
      readline("Provide a directory where to select packages (skip to select the current directory): ")
    },
    help = "Run the comparison using all packages in this directory"
  ),
  optparse::make_option(
    "--packages",
    default = if (interactive()) {
      readline("Provide a comma-separated list of packages (skip to include all directories for sampling): ")
    },
    help = "Run the comparison using these packages (comma-separated)"
  ),
  optparse::make_option(
    "--sample_size",
    type = "integer",
    default = if (interactive()) {
      readline("Enter the number of packages to include (skip to include all): ")
    },
    help = "Select a sample of this number of packages from 'packages' or 'pkg_dir'"
  ),
  optparse::make_option(
    "--outfile",
    default = file.path(".dev", sprintf("lintr_compare_branches_%d.csv", as.integer(Sys.time()))),
    help = "Destination file to which to write the output"
  )
)

params <- optparse::parse_args(optparse::OptionParser(option_list = param_list))
params$outdir <- dirname(params$outfile)

# treat any skipped arguments from the prompt as missing
if (interactive()) {
  for (opt in c("branch", "pr", "packages", "pkg_dir", "sample_size")) {
    # typed arguments get cast even when missing, probably to NA
    if (isTRUE(is.na(params[[opt]]) || params[[opt]] == "")) params[[opt]] <- NULL
  }
  if (isTRUE(is.na(params$base_branch) || params$base_branch == "")) params$base_branch <- "master"
}

linter_names <- strsplit(params$linters, ",", fixed = TRUE)[[1L]]
if (length(linter_names) == 0L) {
  stop("Please supply linters (--linters)")
}

base_branch <- params$base_branch
if (is.null(base_branch) || is.na(base_branch) || !nzchar(base_branch)) {
  stop("Please supply a base branch (--base-branch)")
}

# prioritize "branch"
is_branch <- FALSE
has_target <- TRUE
if (!is.null(params$branch)) {
  branch <- params$branch
  is_branch <- TRUE
} else if (!is.null(params$pr)) {
  pr <- params$pr
} else {
  has_target <- FALSE
}

if (is.null(params$pkg_dir)) {
  # TODO: I think we need to enable running the script outside
  #   the lintr directory in order for this to work. the intention is
  #   to be able to run compare_branches --packages=p1,p2 --linters=l1,l2
  #   and it looks in the executing directory for p1,p2.
  stop("pkg_dir is required")
  params$pkg_dir <- "."
}
packages <- list.files(normalizePath(params$pkg_dir), full.names = TRUE)
if (!is.null(params$packages)) {
  # strip version numbers
  package_names <- gsub("_.*", "", basename(packages))
  packages <- packages[package_names %in% strsplit(params$packages, ",", fixed = TRUE)[[1L]]]
}
# filter to (1) package directories or (2) package tar.gz files
packages <- packages[
  file.exists(packages) &
    (
      file.exists(file.path(packages, "DESCRIPTION")) |
        grepl("^[a-zA-Z0-9.]+_[0-9.-]+\\.tar\\.gz", basename(packages))
    )
]

if (length(packages) == 0L) {
  stop("No packages found!")
}

if (is.null(params$sample_size)) {
  n_packages <- length(packages)
} else {
  if (params$sample_size <= 0) {
    stop("Please request >0 packages")
  }
  if (params$sample_size > length(packages)) {
    message(sprintf(
      "Requested a sample of %d packages but only %d are available; running on all packages",
      params$sample_size,
      length(packages)
    ))
    n_packages <- length(packages)
  } else {
    n_packages <- params$sample_size
  }
  # draw sample & randomize order
  packages <- sample(packages, size = n_packages)
}

# test if nchar(., "chars") works as intended
#   for all files in dir (see #541)
test_encoding <- function(dir) {
  tryCatch(
    {
      lapply(
        list.files(dir, pattern = "(?i)\\.r(?:md)?$", recursive = TRUE, full.names = TRUE),
        function(x) {
          con <- file(x, encoding = lintr:::find_default_encoding(x) %||% "UTF-8")
          on.exit(close(con))
          nchar(readLines(con, warn = FALSE))
        }
      )
      TRUE
    },
    error = function(x) FALSE
  )
}

# read Depends from DESCRIPTION
get_deps <- function(pkg) {
  deps <- read.dcf(file.path(pkg, "DESCRIPTION"), c("Imports", "Depends"))
  deps <- toString(deps[!is.na(deps)])
  if (deps == "") {
    return(character())
  }
  deps <- strsplit(deps, ",", fixed = TRUE)[[1L]]
  deps <- trimws(gsub("\\([^)]*\\)", "", deps))
  deps <- deps[deps != "R"]
  deps
}

lint_one_package <- function(package, linters, out_dir, check_deps) {
  package_is_dir <- file.info(package)$isdir
  package_name <- gsub("_.*", "", basename(package))

  if (!package_is_dir) {
    tmp <- file.path(tempdir(), package_name)
    # TODO: only extract files that lintr::lint_package() cares about
    # package_files <- utils::untar(package, list = TRUE)
    # lint_files <- grep(file.path(package_name, "(R|tests|inst|vignettes|data-raw|demo)"), package_files, value = TRUE)
    # exclude directories because untar() gets confused when extracting path/to and then path/to/file
    # lint_files <- lint_files[!endsWith(lint_files, "/")]
    # --strip-components makes sure the output structure is
    # /path/to/tmp/pkg/ instead of /path/to/tmp/pkg/pkg
    utils::untar(package, exdir = tmp, extras = "--strip-components=1")
    on.exit(unlink(tmp, recursive = TRUE))
    package <- tmp
  }
  if (!test_encoding(package)) {
    warning(sprintf(
      "Package %s has some files with unknown encoding; skipping",
      package_name
    ))
    return(FALSE)
  }
  # object_usage_linter requires running package code, which may
  #   not work if the package has unavailable Depends;
  # object_name_linter also tries to run loadNamespace on Imports
  #   found in the target package's NAMESPACE file
  if (check_deps) {
    package_deps <- get_deps(package)
    if ("tcltk" %in% package_deps && !capabilities("tcltk")) {
      warning(sprintf(
        "Package %s depends on tcltk, which is not available (via capabilities()); skipping",
        package_names[ii]
      ))
      return(FALSE)
    }
    try_deps <- tryCatch(
      find.package(package_deps),
      error = identity,
      warning = identity
    )
    if (inherits(try_deps, c("warning", "error"))) {
      warning(sprintf(
        "Some package Dependencies for %s were unavailable: %s; skipping",
        package_name,
        gsub("there (?:are no packages|is no package) called ", "", try_deps$message)
      ))
      return(FALSE)
    }
  }

  lints <- as.data.frame(lint_dir(package, linters = linters, parse_settings = FALSE))
  if (nrow(lints) > 0L) data.table::fwrite(lints, file.path(out_dir, paste0(package_name, ".csv")))
  TRUE
}

run_workflow <- function(what, packages, linter_names, branch, number) {
  t0 <- Sys.time()
  old_branch <- gert::git_branch()
  on.exit({
    gert::git_branch_checkout(old_branch)
    t1 <- Sys.time()
    message("  Completed on ", what, " in ", format(difftime(t1, t0, units = "mins"), digits = 1L))
  })

  # safe to use force=TRUE because we're in temp_repo
  if (what == "pr") {
    # pr_fetch doesn't expose this so use this to reset
    gert::git_branch_checkout("master", force = TRUE)
    usethis::pr_fetch(number)
  } else {
    gert::git_branch_checkout(branch, force = TRUE)
  }
  pkgload::load_all()

  check_deps <- any(c("object_usage_linter", "object_name_linter") %in% linter_names)
  linters <- lapply(linter_names, function(linter_name) eval(call(linter_name)))
  # accumulate results sequentially to allow for interruptions of long-running executions without losing progress
  out_temp_dir <- file.path(old_wd, params$outdir, ".partial", if (what == "pr") paste0("pr", number) else branch)
  dir.create(out_temp_dir, recursive = TRUE, showWarnings = FALSE)

  linted_packages <- 0L
  package_i <- 0L
  pkgs_width <- as.integer(ceiling(log10(length(packages))))
  done_width <- as.integer(ceiling(log10(n_packages)))
  stdout_width <- getOption("width")
  # given how common it can be to skip packages (e.g. due to uninstalled
  #   dependencies), use a while loop to try and reach n_packages instead
  #   of just iterating over n_packages (which may in actuality lint
  #   far fewer than that number)
  while (linted_packages < n_packages) {
    package_i <- package_i + 1L
    if (package_i > length(packages)) break
    package <- packages[[package_i]]
    package_str <- gsub("_.*", "", basename(package))
    success <- lint_one_package(package, linters, out_temp_dir, check_deps)
    linted_packages <- linted_packages + success
    cat(sprintf(
      "\r[%0*s : %0*s / %d] %s%s",
      pkgs_width, package_i, done_width, linted_packages, n_packages, package_str,
      # {[, ,:, , ,/, ,], }: 9 characters, plus 5 characters extra buffer
      strrep(" ", stdout_width - 14L - pkgs_width - 2 * done_width - nchar(package_str))
    ))
  }
  cat("\n")
  if (linted_packages == 0L) {
    stop("Couldn't successfully lint any packages")
  }
  if (linted_packages < n_packages) {
    message(sprintf("Requested %d packages, but could only lint %d", n_packages, linted_packages))
  }
}

if (has_target) {
  message("Comparing the output of the following linters: ", toString(linter_names))
  if (is_branch) {
    message("Comparing branch ", branch, " to ", base_branch)
    target <- branch
  } else {
    message("Comparing PR#", pr, " to ", base_branch)
    target <- pr
  }
} else {
  message("Running the following linters: ", toString(linter_names))
}
if (length(packages) > 50L) {
  message(
    "Comparing output of lint_dir run on many packages; here are 50: ",
    toString(basename(sample(packages, 50L)))
  )
} else {
  message(
    "Comparing output of lint_dir run for the following packages: ",
    toString(basename(packages))
  )
}

if (dir.exists(file.path(params$outdir, ".partial"))) {
  message(
    "** A .partial directory already exists in ", params$outdir, "; ",
    "these will be included here. Please interrupt & delete these files first if this is not intended"
  )
}

# 3 nested loops, organized for efficiency
#  (1) (outermost) branch (only build & install the package once per branch)
#  (2) (central) packages (only unzip the package once per branch)
#  (3) (innermost) linters (once the package is installed, easy to cycle through linters)
run_workflow("branch", packages, linter_names, branch = base_branch)
if (has_target) {
  if (is_branch) {
    run_workflow("branch", packages, linter_names, branch = target)
  } else {
    run_workflow("pr", packages, linter_names, number = target)
  }
}

setwd(old_wd)
message("Writing output to ", params$outfile)

load_partial_results <- function(target, is_branch) {
  directory <- file.path(params$outdir, ".partial", if (is_branch) target else paste0("pr", target))
  files <- list.files(directory, full.names = TRUE)
  names(files) <- gsub("\\.csv$", "", basename(files))
  purrr::map_df(files, readr::read_csv, show_col_types = FALSE, .id = "package")
}

if (has_target) {
  lints <- dplyr::bind_rows(
    base = load_partial_results(base_branch, TRUE),
    branch = load_partial_results(target, is_branch),
    .id = "source"
  )
} else {
  lints <- load_partial_results(base_branch, TRUE)
}
unlink(file.path(params$outdir, ".partial"), recursive = TRUE)
data.table::fwrite(lints, params$outfile, row.names = FALSE)

if (interactive()) {
  unlink(temp_repo, recursive = TRUE)
} else {
  warnings()
}
