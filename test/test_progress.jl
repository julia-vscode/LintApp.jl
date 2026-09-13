@testitem "ProgressReporter aggregation and multi-bar frames" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)

    # Nothing reported yet -> nothing rendered.
    @test isempty(LintApp._render_frame(pr, 80))

    # The first report makes the whole pre-seeded pipeline visible: the
    # started phase renders live, the others as "waiting" rows, with an
    # explanatory note under the lint bar.
    LintApp._report_parse!(pr, 1, 4)
    f = LintApp._render_frame(pr, 80)
    @test occursin("Parsing files", f[1])
    @test occursin("1/4", f[1])
    @test occursin("Indexing environments", f[2]) && occursin("waiting", f[2])
    @test occursin("Downloading caches", f[3]) && occursin("waiting", f[3])
    @test occursin("Linting files", f[4]) && occursin("waiting", f[4])
    @test occursin("waiting for environment indexing and downloads to finish", f[5])
    @test length(f) == 5

    # Index keys aggregate into one bar with done/seen counts and indented
    # sub-status lines for the active environments.
    LintApp._report_jw!(pr, "index:/proj/a", "Queued", 0)
    LintApp._report_jw!(pr, "index:/proj/b", "Starting", 0)
    LintApp._report_jw!(pr, "index:/proj/a", "Done", 100)
    f = LintApp._render_frame(pr, 80)
    idx = findfirst(l -> occursin("Indexing environments", l), f)
    @test idx !== nothing
    @test occursin("1/2", f[idx])
    @test startswith(f[idx+1], "    ")
    @test occursin("0% — Starting", f[idx+1])

    # A terminal report for a never-active key is a no-op.
    LintApp._report_jw!(pr, "index:/proj/zzz", "Done", 100)
    @test pr.phase_done["index"] == 1

    # Once linting starts its row goes live (no more waiting note), at the
    # bottom of the pipeline.
    LintApp._report_lint!(pr, 1, 3)
    f = LintApp._render_frame(pr, 80)
    lint = findfirst(l -> occursin("Linting files", l), f)
    @test lint == length(f)
    @test occursin("1/3", f[lint])
    @test !any(l -> occursin("waiting for environment indexing", l), f)

    # Live rendering actually wrote the block to the stream.
    s = String(take!(io))
    @test occursin("Linting files", s)
    @test occursin("\e[2K", s)

    # finish erases the block and prints the summary as the last line.
    LintApp._finish_progress!(pr, 3)
    s = String(take!(io))
    @test occursin(r"Analyzed 3 files in \d+(\.\d+)?s", s)
    @test endswith(s, "\n")
    @test occursin(r"Analyzed 3 files in \d+(\.\d+)?s$", split(s, '\n')[end-1])
    @test pr.region_height == 0
end

@testitem "row lifecycle: pipeline order, append-at-bottom, sticky completion" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)

    # Arrival order download -> index -> parse; display order is the fixed
    # pipeline order regardless.
    LintApp._report_jw!(pr, "download:/e/a", "Downloading caches (0/2)...", 0)
    LintApp._report_jw!(pr, "index:/e/a", "Queued", 0)
    LintApp._report_parse!(pr, 1, 5)
    f = LintApp._render_frame(pr, 80)
    order = [findfirst(l -> occursin(s, l), f)
             for s in ("Parsing files", "Indexing environments", "Downloading caches", "Linting files")]
    @test all(!isnothing, order)
    @test issorted(order)

    # Phases outside the standard pipeline append at the bottom.
    LintApp._report_jw!(pr, "bootstrap", "Booting...", 0)
    f = LintApp._render_frame(pr, 80)
    boot = findfirst(l -> occursin("Preparing analysis environment", l), f)
    @test boot == length(f)
    @test occursin("Booting...", f[boot])
    LintApp._report_jw!(pr, "bootstrap", "Done", 100)
    f = LintApp._render_frame(pr, 80)
    @test occursin("done", f[findfirst(l -> occursin("Preparing analysis environment", l), f)])

    # A completed phase keeps its row, with a full bar and final count
    # (full-bar rendering itself is covered by the _bar unit tests).
    LintApp._report_jw!(pr, "download:/e/a", "Done", 100)
    f = LintApp._render_frame(pr, 80)
    dl = f[findfirst(l -> occursin("Downloading caches", l), f)]
    @test occursin("1/1", dl)
    @test occursin("━━", dl)
end

@testitem "refresh phase is hidden" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)

    LintApp._report_jw!(pr, "refresh:/e/docs", "Refreshing environment...", 0)
    LintApp._report_jw!(pr, "refresh:/e/docs", "Done", 100)
    @test isempty(pr.phase_started)
    @test !haskey(pr.phase_done, "refresh")
    @test isempty(LintApp._render_frame(pr, 80))
    @test isempty(String(take!(io)))

    # Plain mode too.
    prp = LintApp.ProgressReporter(io, false)
    LintApp._report_jw!(prp, "refresh:/e/docs", "Refreshing environment...", 0)
    @test isempty(String(take!(io)))
end

@testitem "live lint total can change mid-run" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)

    LintApp._report_lint!(pr, 5, 10)
    f = LintApp._render_frame(pr, 80)
    @test occursin("5/10", f[findfirst(l -> occursin("Linting files", l), f)])

    # An extra analysis pass can grow the total; the bar adapts in place.
    LintApp._report_lint!(pr, 5, 20)
    f = LintApp._render_frame(pr, 80)
    @test occursin("5/20", f[findfirst(l -> occursin("Linting files", l), f)])

    # Clearing erases the block without printing a summary.
    LintApp._clear_progress!(pr)
    @test pr.region_height == 0
    @test !occursin("Analyzed", String(take!(io)))
end

@testitem "Pkg-style bar rendering" begin
    # Plain (no color): heavy fill, space track, no head glyph — Pkg behavior.
    @test LintApp._bar(3, 10, 10) == "━━━       "
    @test LintApp._bar(0, 10, 10) == " "^10
    @test LintApp._bar(10, 10, 10) == "━"^10
    # done > total clamps instead of overflowing the bar.
    @test LintApp._bar(15, 10, 10) == "━"^10

    # Color: green fill, light_black track, half-glyph head at the boundary.
    b = LintApp._bar(3, 10, 10; color=true)
    @test occursin("\e[32m", b) && occursin("\e[90m", b)
    @test occursin("╺", b)      # fractional cell not yet half full
    b = LintApp._bar(7, 12, 10; color=true)
    @test occursin("╸", b)      # fractional cell more than half full

    # Pending track: no head glyph, grey with color, spaces without.
    @test LintApp._track(8) == " "^8
    @test LintApp._track(8; color=true) == "\e[90m" * "━"^8 * "\e[0m"

    # Width bounds.
    @test 10 <= LintApp._bar_length(500, "Linting files ") <= 40
    @test LintApp._bar_length(60, "Linting files ") < 40

    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)
    LintApp._report_lint!(pr, 1, 2059)
    f = LintApp._render_frame(pr, 500)
    line = f[findfirst(l -> occursin("Linting files", l), f)]
    @test occursin("1/2059", line)
    @test !occursin("|", line)  # no delimiters in the Pkg style
end

@testitem "frame lines never exceed the terminal width" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)
    LintApp._report_jw!(pr, "index:/some/very/long/path/PackageWithAVeryLongName",
                        "Indexing PackageWithAVeryLongName with quite a long message...", 10)
    LintApp._report_lint!(pr, 1, 100)
    f = LintApp._render_frame(pr, 30)
    @test !isempty(f)
    @test all(l -> length(l) <= 29, f)
end

@testitem "region redraw blanks leftover rows when the frame shrinks" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)

    LintApp._draw_region!(pr, ["a", "b", "c", "d", "e"])
    s = String(take!(io))
    @test count("\e[2K", s) == 5
    @test occursin("\e[5A", s)
    @test pr.region_height == 5

    # Shrinking frame: the three leftover rows are blanked, cursor-up spans
    # everything that was touched.
    LintApp._draw_region!(pr, ["x", "y"])
    s = String(take!(io))
    @test count("\e[2K", s) == 5
    @test occursin("\e[5A", s)
    @test pr.region_height == 2

    LintApp._clear_region!(pr)
    s = String(take!(io))
    @test count("\e[2K", s) == 2
    @test pr.region_height == 0

    # Nothing on screen -> clearing writes nothing.
    LintApp._clear_region!(pr)
    @test isempty(String(take!(io)))
end

@testitem "progress key display names" begin
    # Without a lint target every environment keeps its absolute path.
    @test LintApp._key_display_name("index:/proj/MyPkg") == "/proj/MyPkg"
    @test LintApp._key_display_name("index:/proj/MyPkg/") == "/proj/MyPkg"

    # Relative to the lint target, which is what makes a large environment
    # count legible: these are nested projects, and only the path says so.
    root = Sys.iswindows() ? "C:\\proj" : "/proj"
    @test LintApp._key_display_name("index:" * joinpath(root, "packages", "Foo"), root) == "packages/Foo"
    @test LintApp._key_display_name("index:" * joinpath(root, "docs"), root) == "docs"

    # The target itself is named, not rendered as ".".
    @test LintApp._key_display_name("index:" * root, root) == "proj"

    # A path outside the target stays absolute.
    outside = Sys.iswindows() ? "C:\\elsewhere\\Other" : "/elsewhere/Other"
    @test LintApp._key_display_name("index:" * outside, root) == "C:/elsewhere/Other" ||
          LintApp._key_display_name("index:" * outside, root) == "/elsewhere/Other"

    # A case-only difference between the target and the key (Windows paths
    # round-trip through URIs) still resolves to the relative form.
    @test LintApp._key_display_name("index:" * joinpath(root, "docs"), uppercase(root)) ==
          (Sys.iswindows() ? "docs" : LintApp._display_path(joinpath(root, "docs"), ""))

    # Test-environment keys carry the package name after the path. Tagging the
    # path beats showing the bare package name: a package and its test
    # environment are then distinguishable, and so are same-named packages.
    @test LintApp._key_display_name("index:/proj/a:TestPkg") == "/proj/a (test env)"
    @test LintApp._key_display_name("index:" * joinpath(root, "a") * ":TestPkg", root) == "a (test env)"

    # A Windows drive letter is not a package name: parse from the right.
    @test LintApp._key_display_name("index:C:\\proj\\MyPkg") == "C:/proj/MyPkg"
    @test LintApp._key_display_name("download:C:\\envs\\v1.12") == "C:/envs/v1.12"
end

@testitem "showvalues detail lines" begin
    root = Sys.iswindows() ? "C:\\p" : "/p"
    active = Dict(
        "index:" * joinpath(root, "a") => (10, "Indexing a..."),
        "index:" * joinpath(root, "b") => (80, "Indexing b..."),
        "index:" * joinpath(root, "c") => (50, "Indexing c..."),
    )
    vals = LintApp._active_showvalues(active, root, 80)
    @test vals == [("b", "80% — Indexing b..."),
                   ("c", "50% — Indexing c..."),
                   ("a", "10% — Indexing a...")]

    # More active keys than lines: cap and summarize the rest. Names are padded
    # to a common width so the percentages line up under each other.
    active = Dict("index:" * joinpath(root, "x$i") => (i, "m") for i in 1:6)
    vals = LintApp._active_showvalues(active, root, 80)
    @test length(vals) == 5
    @test last(vals) == ("… ", "+2 more")

    # The per-environment package counter "(i/n)" is stripped: next to the
    # environment percentage, a second unrelated counter only confuses.
    active = Dict("index:" * joinpath(root, "Mimi") => (38, "Indexing Mimi (2/2)..."),
                  "index:" * joinpath(root, "a") => (17, "Indexing Foo_jll (1/1)..."))
    vals = LintApp._active_showvalues(active, root, 80)
    @test vals == [("Mimi", "38% — Indexing Mimi..."),
                   ("a   ", "17% — Indexing Foo_jll...")]

    # A long path elides from the left, keeping the distinguishing tail.
    deep = joinpath(root, "packages", "Preferences", "test", "UsesPreferences")
    vals = LintApp._active_showvalues(Dict("index:" * deep => (5, "Indexing...")), root, 60)
    name = first(only(vals))
    @test startswith(name, "…")
    @test endswith(name, "test/UsesPreferences")
    @test length(name) == LintApp._name_budget(60)

    # The "(test env)" tag sits in the tail, so it survives elision.
    vals = LintApp._active_showvalues(Dict("index:" * deep * ":UsesPreferences" => (5, "Starting...")), root, 60)
    @test endswith(first(only(vals)), " (test env)")
end

@testitem "index detail lines name environments by path" begin
    root = Sys.iswindows() ? "C:\\ws" : "/ws"
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true; root=root)
    LintApp._report_jw!(pr, "index:" * joinpath(root, "docs"), "Queued for indexing...", 0)
    f = LintApp._render_frame(pr, 100)
    idx = findfirst(l -> occursin("Indexing environments", l), f)
    @test idx !== nothing
    @test occursin("    docs", f[idx+1])
    @test occursin("0% — Queued for indexing...", f[idx+1])
end

@testitem "ProgressReporter plain-mode throttling" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, false)

    # First report is a phase transition and always renders, as a full line.
    LintApp._report_lint!(pr, 1, 100)
    @test String(take!(io)) == "Linting files (1/100)\n"

    # Same-phase count updates inside the throttle window stay quiet.
    LintApp._report_lint!(pr, 2, 100)
    @test isempty(String(take!(io)))

    # Once the window has passed, the next update renders.
    pr.last_render = time() - 10.0
    LintApp._report_lint!(pr, 50, 100)
    @test String(take!(io)) == "Linting files (50/100)\n"

    # A phase transition bypasses the throttle.
    LintApp._report_jw!(pr, "index:/proj/a", "Queued", 0)
    @test isempty(String(take!(io)))  # lint still underway, label unchanged
    LintApp._report_lint!(pr, 100, 100)
    @test String(take!(io)) == "Indexing environments (0/1)\n"

    # Parsing gets its own plain label while underway.
    LintApp._report_parse!(pr, 1, 4)
    @test String(take!(io)) == "Parsing files (1/4)\n"

    # Plain-mode finish has no clear sequence, just the summary line.
    LintApp._finish_progress!(pr, 100)
    s = String(take!(io))
    @test !occursin("\e[2K", s)
    @test occursin("Analyzed 100 files in ", s)
end

@testitem "CLI progress on stderr" setup=[CLIHelper] begin
    run_cli, CLEAN, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.CLEAN, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), CLEAN)
    write(joinpath(dir, "b.jl"), SYNTAX_ERROR)

    # Captured stderr is not a TTY, so progress uses plain lines: parsing
    # first, then the lint sweep.
    code, out, err = run_cli([dir])
    @test code == 1
    @test occursin("Parsing files (", err)
    @test occursin("Linting files (", err)
    @test occursin("Analyzed 2 files in ", err)
    @test !occursin("Linting files", out)

    # --no-progress silences it entirely.
    _, _, err = run_cli(["--no-progress", dir])
    @test !occursin("Linting files", err)
    @test !occursin("Analyzed", err)
end

@testitem "-o output identical with and without progress" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    f1 = joinpath(mktempdir(), "with.txt")
    f2 = joinpath(mktempdir(), "without.txt")
    run_cli(["--output-file", f1, dir])
    run_cli(["--no-progress", "--output-file", f2, dir])
    @test read(f1, String) == read(f2, String)
end
