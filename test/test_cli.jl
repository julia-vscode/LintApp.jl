@testitem "parse_commandline defaults" begin
    parsed = LintApp.parse_commandline(String[])
    @test parsed["path"] == ""
    @test parsed["format"] == "text"
    @test parsed["verbose"] == false
    @test parsed["quiet"] == false
    @test parsed["max-warnings"] == -1
    @test parsed["output-file"] === nothing
end

@testitem "nonexistent path" setup=[CLIHelper] begin
    run_cli = CLIHelper.run_cli

    code, _, err = run_cli([joinpath(mktempdir(), "does-not-exist")])
    @test code == 1
    @test occursin("path does not exist", err)
end

@testitem "clean directory" setup=[CLIHelper] begin
    run_cli, CLEAN = CLIHelper.run_cli, CLIHelper.CLEAN

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), CLEAN)

    code, out, _ = run_cli([dir])
    @test code == 0
    @test !occursin("error", out)
end

@testitem "syntax error produces an error finding and exit 1" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    code, out, _ = run_cli([dir])
    @test code == 1
    # Windows drive letters may round-trip through URIs with different casing.
    @test occursin("bad.jl", lowercase(out))
    @test occursin("error", out)

    # --verbose shows source context with a caret marker.
    code, out, _ = run_cli(["--verbose", dir])
    @test code == 1
    @test occursin("-->", out)
    @test occursin("^", out)
end

@testitem "JuliaLint.toml disables a rule" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)
    write(joinpath(dir, "JuliaLint.toml"), """
    [rules]
    syntax_errors = "off"
    """)

    code, out, _ = run_cli([dir])
    @test code == 0
    @test !occursin("bad.jl", lowercase(out))
end

@testitem "JuliaLint.toml exclude prunes the directory walk" setup=[CLIHelper] begin
    run_cli, CLEAN, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.CLEAN, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    for name in ("a.jl", "b.jl", "c.jl")
        write(joinpath(dir, name), CLEAN)
    end

    # A vendored subtree with its own environment: exactly the shape that used
    # to cost an indexer child process despite being excluded.
    mkpath(joinpath(dir, "vendor"))
    write(joinpath(dir, "vendor", "bad.jl"), SYNTAX_ERROR)
    write(joinpath(dir, "vendor", "other.jl"), CLEAN)
    write(joinpath(dir, "vendor", "Project.toml"), """
    name = "Vendored"
    uuid = "3a1e2b4c-5d6f-4a7b-8c9d-0e1f2a3b4c5d"
    """)
    write(joinpath(dir, "JuliaLint.toml"), """
    exclude = ["vendor/**"]
    """)

    code, out, err = run_cli([dir])
    @test code == 0
    @test !occursin("bad.jl", lowercase(out))

    # The excluded files are not merely unreported — they are never read. The
    # parse counter on stderr covers exactly the files the walk collected, so
    # it is 3 (the root sources) and not 5, and `vendor/Project.toml` never
    # becomes an environment to resolve.
    m = match(r"Parsing files \(\d+/(\d+)\)", err)
    @test m !== nothing
    @test parse(Int, m[1]) == 3
end

@testitem "json output" setup=[CLIHelper] begin
    using JSON

    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    code, out, _ = run_cli(["--format", "json", dir])
    @test code == 1
    parsed = JSON.parse(out)
    @test parsed isa Vector
    @test length(parsed) == 1
    @test occursin("bad.jl", lowercase(parsed[1]["file"]))
    diags = parsed[1]["diagnostics"]
    @test !isempty(diags)
    d = diags[1]
    @test d["severity"] == "error"
    @test haskey(d, "message")
    @test haskey(d, "rule")
    @test d["startLine"] isa Integer
end

@testitem "sarif output" setup=[CLIHelper] begin
    using JSON

    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    code, out, _ = run_cli(["--format", "sarif", dir])
    @test code == 1
    sarif = JSON.parse(out)
    @test sarif["version"] == "2.1.0"
    run = sarif["runs"][1]
    @test run["tool"]["driver"]["name"] == "julialint"
    results = run["results"]
    @test !isempty(results)
    r = results[1]
    @test r["level"] == "error"
    @test !isempty(r["ruleId"])
    loc = r["locations"][1]["physicalLocation"]
    @test loc["artifactLocation"]["uri"] == "bad.jl"
    @test loc["region"]["startLine"] == 1
end

@testitem "output file" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)
    out_file = joinpath(mktempdir(), "lint.txt")

    code, out, _ = run_cli(["--output-file", out_file, dir])
    @test code == 1
    @test isempty(out)
    @test occursin("bad.jl", lowercase(read(out_file, String)))
end
