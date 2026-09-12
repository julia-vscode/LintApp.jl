# LintApp.jl

> [!WARNING]
> **LintApp is beta software.** It is still under active development, may be
> unstable, and everything described here — including commands, options, output,
> and the configuration format — is subject to change without notice.

`julialint` is a command line static analysis tool for Julia. It exposes the
linting capabilities of [JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl)
as a standalone app, and is a companion to [FormatApp.jl](https://github.com/julia-vscode/FormatApp.jl).

`julialint` analyzes Julia source files and reports diagnostics — errors,
warnings, information, and hints — that help you catch problems before running
your code. Diagnostics can be printed as human-readable text, or emitted as JSON
or SARIF for integration with other tools and CI systems.

## Installation

`julialint` is a [Julia app](https://pkgdocs.julialang.org/dev/apps/) and requires
Julia 1.12 or newer. Install it with the `app` command in the package REPL:

```
pkg> app add LintApp
```

This installs the `julialint` executable into `~/.julia/bin`. Make sure that
directory is on your `PATH`.

## Usage

```
julialint [options] [path]
```

`path` may be a single directory. The directory is searched recursively for
Julia files. When no path is given, the current directory is used.

### Options

| Option | Description |
| --- | --- |
| `-f`, `--format FORMAT` | Output format: `text` (default), `json`, or `sarif`. |
| `-v`, `--verbose` | Show source context around each diagnostic. |
| `-q`, `--quiet` | Show only errors (suppress warnings, info, and hints). |
| `--max-warnings N` | Exit with code `1` if the warning count exceeds `N` (`-1` = unlimited). |
| `-o`, `--output-file FILE` | Write output to a file instead of stdout. |
| `--no-progress` | Disable progress output. |
| `--log LEVEL` | Set the log level (`debug` or `info`); warnings and errors are always shown. |
| `--version` | Print the version and exit. |
| `-h`, `--help` | Print help and exit. |

### Examples

```sh
# Lint every Julia file under src/
julialint src/

# Lint the current directory
julialint

# Show source context around each diagnostic
julialint --verbose src/

# Show only errors
julialint --quiet src/

# Fail (exit code 1) if there are more than 10 warnings — useful in CI
julialint --max-warnings 10 src/

# Emit JSON for tooling
julialint --format json -o diagnostics.json src/

# Emit SARIF for GitHub Code Scanning
julialint --format sarif -o results.sarif src/
```

## Progress output

While `julialint` works it reports progress on **stderr**, so it never mixes
with diagnostics on stdout (or a `-o` file). The run parses all files while
the project environments are indexed in the background, then performs a single
analysis pass once indexing is complete. When stderr is a terminal, progress is
a live multi-bar display in the style of Julia's package manager: the
pipeline's phases — parsing, environment indexing, symbol-cache downloads,
linting — are shown as progress bars from the start (phases that have not
begun are marked as waiting), with indented sub-status lines showing which
environments are being worked on right now. When stderr is redirected
(e.g. in CI logs), plain throttled status lines are printed instead. Either way
the run ends with a summary line like `Analyzed 128 files in 12.3s`.

`--no-progress` disables progress output entirely, and `--log debug`/`--log
info` falls back to the plain status lines so log records and the live display
don't fight over the terminal.

## Output formats

| Format | Description |
| --- | --- |
| `text` | Human-readable diagnostics with a summary count. Use `--verbose` for Rust/clippy-style source context with caret markers. |
| `json` | Structured diagnostics grouped by file, suitable for further processing. |
| `sarif` | SARIF v2.1.0 output compatible with GitHub Code Scanning and other SARIF consumers. |

Every format reports the **rule id** of each finding — in brackets in `text`
output, as the `rule` field in `json`, and as the SARIF `ruleId`. That id is
what you write in `JuliaLint.toml` to change or silence the rule, and what
GitHub Code Scanning keys per-rule suppressions on:

```
src/MyPackage.jl:5:5: error: Variable has been assigned but not used. [unused_binding]
```

## Configuration

> [!WARNING]
> The `JuliaLint.toml` configuration format is **experimental**. The available
> keys, their values, and default behavior may change in any release without
> notice.

Linting behavior is customized with a `JuliaLint.toml` file (the name is matched
case-insensitively). Place it in your project; it applies to all Julia files in
that directory and its subdirectories.

**The nearest configuration file governs a file wholesale.** When several
`JuliaLint.toml` files exist along a path, only the closest one applies —
settings are *not* merged across files. Keys the governing file does not set
take their built-in defaults, never a value from a file further up the tree.
This means you can always determine a directory's effective configuration by
reading exactly one file.

A single `JuliaLint.toml` at the project root should be your default. When part
of the tree needs different settings, use an `[[override]]` block in that one
file rather than a second config file — a nested file is a last resort, for a
subtree that is genuinely independent of the project, such as a vendored
repository.

Because a nested config *replaces* rather than extends the one above it — which
would otherwise happen silently — a config file with another of the same kind in
an enclosing directory reports a `shadowed_config` diagnostic (`info` severity
by default) naming the file it takes over from. Projects that genuinely want
independent subtrees set `shadowed_config = "off"`.

### Top-level keys

| Key | Default | Description |
| --- | --- | --- |
| `config-version` | `1` | The config format version. Absent means `1`. |
| `preset` | `"default"` | The severity baseline: `"minimal"`, `"default"`, or `"strict"`. |
| `include` | all `.jl` files | Glob patterns selecting the files to lint. |
| `exclude` | none | Glob patterns excluding files from linting. Wins over `include`. |
| `[rules]` | — | Per-rule severity and options, applied on top of the preset. |
| `[[override]]` | — | Re-scope a subset of the settings to matching paths. |

Globs are gitignore-style, relative to the directory holding the config file:
`*` matches within a path segment, `**` spans segments, `?` matches a single
character, and a pattern with no `/` matches at any depth.

### Presets

| Preset | Description |
| --- | --- |
| `minimal` | Only outright breakage: syntax, test item, TOML and config errors, plus include-graph and `const` problems. |
| `default` | The out-of-the-box behavior. |
| `strict` | Every rule on, with hints and informational findings promoted to warnings. |

A preset name **floats** — it tracks the tool rather than pinning a frozen rule
set, so upgrading `julialint` can change what a preset reports. To keep that
from breaking projects, a rule that did not exist before enters existing presets
as `"off"`; promoting it is a deliberate, changelogged change. Version-pinning
syntax may be added later, and bare names will keep floating.

#### Rules that are off by default

Three long-standing checks are `off` in `default`: `incorrect_call_args`,
`missing_reference` and `unresolved_import`.

Each needs a complete picture of something the analysis often cannot see in
full — the method set of a callee, every name a module defines, the environment
an import resolves against — and reports anyway when that picture is
incomplete. On a sweep of the 100 most-depended-upon registered packages their
sampled false-positive rates were 93%, 78% and 77%, together about 92% of every
false positive measured.

They are on in `strict`, and any project can restore one:

```toml
[rules]
missing_reference = "warning"
```

They do find real bugs — the same sweep turned up genuine `UndefVarError`s and
`MethodError`s through them — so turning them on is worthwhile, just expect to
tune around the noise.

### Rules

Each entry under `[rules]` maps a rule id to a severity — one of `"off"`,
`"hint"`, `"info"`, `"warning"` or `"error"`. A rule that takes options is
written as a table instead, with the severity under the reserved `severity` key:

```toml
[rules]
unused_binding = "warning"
missing_reference = { severity = "warning", scope = "symbols" }
```

Rule ids are stable: they are what you write here, what the language server
reports as a diagnostic code, and what `--format sarif` emits as the SARIF
`ruleId` (so per-rule suppression in GitHub Code Scanning works).

| Rule | Default | Description |
| --- | --- | --- |
| `syntax_errors` | `error` | Julia syntax errors. |
| `syntax_warnings` | `off` | Julia syntax warnings. |
| `testitem_errors` | `error` | Errors in `@testitem` blocks. |
| `toml_syntax_errors` | `error` | TOML syntax errors in config, `Project.toml` and `Manifest.toml` files. |
| `config_errors` | `error` | Invalid keys or values in a `JuliaLint.toml`, `JuliaFormat.toml` or `JuliaTestItems.toml` file. |
| `shadowed_config` | `info` | A config file that supersedes another of the same kind in an enclosing directory (see below). |
| `environment_errors` | `info` | A project or test environment that could not be resolved, reported on its `Project.toml`. |
| `incorrect_call_args` | `off` | Possible method call errors (wrong number/type of arguments), and calls to functions with no methods. Off by default; see below. |
| `incorrect_iter_spec` | `info` | Loop iterators that will likely error. |
| `index_from_length` | `info` | Indexing with indices from `length`/`size`; prefer `eachindex`/`axes`. |
| `nothing_comparison` | `info` | Comparisons against `nothing` that should use `isnothing`/`===`. |
| `const_if_condition` | `info` | Boolean literals and unbracketed assignment used as an `if` condition. |
| `pointless_boolean` | `info` | `&&`/`\|\|` whose first argument is a boolean literal. |
| `invalid_type_declaration` | `info` | Non-`DataType` values used in a type declaration. |
| `unused_type_parameter` | `hint` | Type parameters declared but never used. |
| `module_name` | `info` | A module whose name matches that of its parent. |
| `type_piracy` | `info` | Type piracy, and overloading `!=` instead of `==`. |
| `unused_function_argument` | `hint` | Function arguments declared but never used. |
| `duplicate_function_argument` | `info` | Repeated argument names in a signature. |
| `kw_default_mismatch` | `info` | Keyword default values that don't match the argument type. |
| `literal_use` | `info` | Inappropriate use of literal values. |
| `break_continue` | `info` | `break`/`continue` used outside a loop. |
| `global_const_decl` | `info` | Type declarations on globals and `const` on locals. |
| `const_decl` | `info` | Invalid `const` declarations and redefinitions. |
| `unused_binding` | `hint` | Variables assigned but never used. |
| `relative_import` | `info` | A relative import with more leading dots than available nesting. |
| `include_errors` | `warning` | Circular, duplicate, missing or unreadable `include`s. |
| `missing_reference` | `off` | Unresolved references. Takes a `scope` option: `"none"`, `"symbols"` (identifiers only) or `"all"` (the default). Off by default; see below. |
| `unresolved_import` | `off` | Imports whose target could not be resolved. Off by default; see below. |
| `nan_comparison` | `off` | Comparison against `NaN`, which is never equal to anything; use `isnan`. |
| `duplicate_branch_condition` | `off` | The same condition tested twice in one `if`/`elseif` chain. |
| `string_concat_style` | `off` | String literals concatenated with `*` where interpolation or `string(x, …)` reads better. |
| `bare_using` | `off` | Bare `using Foo` rather than an explicit name list or `import Foo`. |
| `debug_statement` | `off` | `@show`, which usually indicates a leftover debug statement. |
| `async_task` | `off` | `@async`, which pins the task to the current thread; usually `Threads.@spawn` is wanted. |

### Overrides

An `[[override]]` block re-scopes any subset of the settings to the paths its
`paths` globs match. Later blocks win over earlier ones.

```toml
[[override]]
paths = ["test/**"]

[override.rules]
unused_binding = "off"
```

### Example

```toml
# JuliaLint.toml

preset = "default"
exclude = ["gen/**"]

[rules]
# Surface syntax warnings in addition to errors
syntax_warnings = "warning"

# Report every missing reference, not just identifiers
missing_reference = { severity = "warning", scope = "all" }

# Turn off a couple of noisy checks
unused_function_argument = "off"
literal_use = "off"

# Fail CI on anything comparing against `nothing` with `==`
nothing_comparison = "error"

# Tests are noisier by nature
[[override]]
paths = ["test/**"]

[override.rules]
unused_binding = "off"
```

### Migrating from the old format

The earlier flat schema (`static-lint`, `nothingcomp`, `missing-refs`,
`break-continue`, …) is no longer honored. An existing config file is not
silently ignored: each old key produces a diagnostic on the config file naming
its replacement, so `julialint` on your own project tells you what to change.

Note that a project which relied on `static-lint = false` will start reporting
lint diagnostics again until its config is migrated — use `preset = "minimal"`
for the closest equivalent.

### Full reference

This page covers what `julialint` needs. For the complete specification —
the discovery and override mechanism shared with `JuliaFormat.toml` and
`JuliaTestItems.toml`, the glob grammar, and how rules map onto the analysis
internally — see the
[JuliaWorkspaces configuration reference](https://www.julia-vscode.org/JuliaWorkspaces.jl/dev/configuration/).

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success; no errors (and, with `--max-warnings`, the warning limit was not exceeded). |
| `1` | Errors were found, the warning limit was exceeded, or the given path is not a directory. |
| `2` | `julialint` itself failed to analyze the project. Re-run with `--log debug` for the full stack trace. |
