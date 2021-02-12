# Saving and loading happens in a nested fashion:
# save(filename, mc) calls
#   save_mc(filename, mc) calls
#       save_model(filename, mc.model) calls
#           save_lattice(filename, mc.lattice) (TODO, not used yet)
#       save_measurements(filename, mc) calls
#           save_measurement(filename, measurement)
#
# loading follows the same structure
# > Each level (beyond the outermost save) also has an argument `entryname::String`.
# > Each save_something() should write a "VERSION" and a "type" to the file. The
#   former simplifies updates down the line, the latter allows for dispatch.
# > Each load_something should be dispatched on a type, e.g.
#   `load_model(data, ::Type(HubbardModelAttractive))`


# Loading:
# load(filename[, groups]) 
#   - loads from filename, maybe specific group
#   - jumps into _load at fitting part
# _load(data, ::Type{...})
#   - loads from Dict or JLD2.JLDFile or JLD2.Group (data) to some type (for dispatch)

# TODOs:
# - rename save_x to _save(filename, ::X, entryname) (mirror _load)
# - make _load less volatile to changes, i.e. change Type -> Val{Symbol}


"""
    save(filename, mc; overwrite=false, rename=true)

Saves the given MonteCarlo simulation `mc` to a JLD-file `filename`.

If `rename = true` the filename will be adjusted if it already exists. If
`overwrite = true` it will be overwritten. In this case a temporary backup
will be created. If neither are true an error will be thrown.
"""
function save(
        filename, mc::MonteCarloFlavor; 
        overwrite = false, rename = true, compress = true, 
        backend = endswith(filename, "jld2") ? JLD2 : JLD, kwargs...
    )
    # endswith(filename, ".jld") || (filename *= ".jld")

    # handle ranming and overwriting
    isfile(filename) && !overwrite && !rename && throw(ErrorException(
        "Cannot save because \"$filename\" already exists. Consider setting " *
        "`rename = true` to adjust the filename or `overwrite = true`" *
        " to overwrite the file."
    ))
    if isfile(filename) && !overwrite && rename
        filename = _generate_unique_filename(filename)
    end

    temp_filename = ""
    if isfile(filename) && overwrite
        parts = splitpath(filename)
        parts[end] = "." * parts[end]
        temp_filename = _generate_unique_filename(joinpath(parts...))
        mv(filename, temp_filename)
    end

    mode = isfile(filename) ? "r+" : "w"
    file = backend.jldopen(filename, mode, compress=compress; kwargs...)

    write(file, "VERSION", 1)
    save_mc(file, mc, "MC")
    save_rng(file)
    close(file)

    if overwrite && !isempty(temp_filename) && isfile(temp_filename)
        rm(temp_filename)
    end

    return filename
end

# Something like
# existing_file.jld -> existing_file_aJ3c.jld
function _generate_unique_filename(filename)
    isfile(filename) || return filename
    x = rand("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    s = "_$(Char(x))"
    parts = split(filename, '.')
    filename = join(parts[1:end-1], '.') * s
    while isfile(filename * '.' * parts[end])
        x = rand("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        s = string(Char(x))
        filename = filename * s
    end
    filename * '.' * parts[end]
end

"""
    load(filename[, groups...])

Loads a MonteCarlo simulation (or part thereof) from the given JLD-file 
`filename`.
"""
function load(filename, groups::String...)
    data = if endswith(filename, "jld2")
        JLD2.jldopen(filename, "r") else JLD.load(filename)
    end
    output = if haskey(data, "MC") && !("MC" in groups)
        _load(data, "MC", groups...) else _load(data, groups...)
    end
    endswith(filename, "jld2") && close(data)
    output
end
_load(data, g1::String, g2::String, gs::String...) = _load(data[g1], g2, gs...)
function _load(data, g::String)
    if !(data["VERSION"] == 1)
        throw(ErrorException("Failed to load $filename version $(data["VERSION"])"))
    end

    haskey(data[g], "RNG") && load_rng!(data)

    # type nonsense for dispatch
    T = if haskey(data[g], "type"); data[g]["type"] 
    elseif g == "Measurements"; Measurements
    else throw(ErrorException(
        "Failed to defer type for group \"$g\". To fix this, add a group " *
        "\"type\" under \"$g\" with the relevant type. To manually load this " *
        "group, call `MonteCarlo._load(::JLD2.Group, type)`."
    ))
    end
    _load(data[g], T)
end
_load(data) = _load(data, data["type"])


"""
    resume!(filename[; kwargs...])

Resumes a Monte Carlo simulation from a savefile generated by `run!(mc)`. Takes
the same keyword arguments as `run!`. Returns the simulation and the state
returned by `run!`.

See also: [`run!`](@ref)
"""
function resume!(filename; kwargs...)
    data = if endswith(filename, "jld2")
        JLD2.jldopen(filename, "r") else JLD.load(filename)
    end

    if !(data["VERSION"] == 1)
        throw(ErrorException("Failed to load $filename version $(data["VERSION"])"))
    end

    mc = _load(data["MC"], data["MC"]["type"])
    resume_init!(mc)
    load_rng!(data)
    endswith(filename, "jld2") && close(data)

    state = run!(mc; kwargs...)
    mc, state
end


function save_mc(
        filename::String, mc::MonteCarloFlavor, entryname::String="MC"; 
        backend = endswith(filename, "jld2") ? JLD2 : JLD,
        kwargs...
    )
    mode = isfile(filename) ? "r+" : "w"
    file = backend.jldopen(filename, mode; kwargs...)
    save_mc(file, mc, entryname)
    close(file)
    nothing
end
_load(_, ::Type{UnknownType}) = throw(ErrorException(
    "Got UnknownType instead of a MonteCarloFlavor. This may be " * 
    "caused by missing imports."
))
function _load(data, ::JLD2.UnknownType)
    @info "Failed to load (Unknowntype)"
    @info "Available fields: $(keys(data))"
    @info "You may be missing external packages."
    nothing
end




#     save_model(filename, model, entryname)
#
# Save (minimal) information necessary to reconstruct the given `model` in a
# jld-file `filename` under group `entryname`.
#
# By default the full model object is saved. When saving a simulation, the
# entryname defaults to `MC/Model`.
function save_model(
        filename::String, model, entryname::String; 
        backend = endswith(filename, "jld2") ? JLD2 : JLD, kwargs...
    )
    mode = isfile(filename) ? "r+" : "w"
    file = backend.jldopen(filename, mode; kwargs...)
    save_model(file, model, entryname)
    close(file)
    nothing
end
function save_model(file::JLDFile, model, entryname::String)
    write(file, entryname * "/VERSION", 0)
    write(file, entryname * "/type", typeof(model))
    write(file, entryname * "/data", model)
    nothing
end

"""
    _load(data, ::Type{...})

Loads `data` where `data` is either a `JLD2.JLDFile`, `JLD2.Group` or a `Dict`.

The default `_load` will check that `data["VERSION"] == 0` and simply return 
`data["data"]`. You may implement `_load(data, ::Type{<: MyType})` to add
specialized loading behavior.
"""
function _load(data, ::Type{T}) where T
    data["VERSION"] == 0 || throw(ErrorException(
        "Version $(data["VERSION"]) incompatabile with default _load for $T."
    ))
    data["data"]
end


#     save_lattice(filename, lattice, entryname)
#
# Save (minimal) information necessary to reconstruct the given `lattice` in a
# jld-file `filename` under group `entryname`.
#
# By default the full lattice object is saved. When saving a simulation, the
# entryname defaults to `MC/Model/Lattice`.
function save_lattice(
        filename::String, lattice::AbstractLattice, entryname::String; 
        backend = endswith(filename, "jld2") ? JLD2 : JLD, kwargs...
    )
    mode = isfile(filename) ? "r+" : "w"
    file = backend.jldopen(filename, mode; kwargs...)
    save_lattice(file, lattice, entryname)
    close(file)
    nothing
end
function save_lattice(file::JLDFile, lattice::AbstractLattice, entryname::String)
    write(file, entryname * "/VERSION", 0)
    write(file, entryname * "/type", typeof(lattice))
    write(file, entryname * "/data", lattice)
    nothing
end


const _GLOBAL_RNG = VERSION < v"1.3.0" ? Random.GLOBAL_RNG : Random.default_rng()

"""
    save_rng(filename [; rng = _GLOBAL_RNG, entryname = "RNG"])

Saves the current state of Julia's random generator (`Random.GLOBAL_RNG`) to the
given `filename`.
"""
function save_rng(
        filename::String; rng = _GLOBAL_RNG, entryname::String="RNG", 
        backend = endswith(filename, "jld2") ? JLD2 : JLD, kwargs...
    )
    mode = isfile(filename) ? "r+" : "w"
    file = backend.jldopen(filename, mode; kwargs...)
    save_rng(file, rng=rng, entryname=entryname)
    close(file)
end
function save_rng(file::JLDFile; rng = _GLOBAL_RNG, entryname::String="RNG")
    try
        write(file, entryname, rng)
    catch e
        error("Error while saving RNG state: ", e)
    end
end

"""
    load_rng!(data[; rng = _GLOBAL_RNG, entryname = "RNG"])

Loads an RNG from a given `data` dictinary generated by `JLD.load()` to `rng`.
"""
function load_rng!(data; rng = _GLOBAL_RNG, entryname::String="RNG")
    try
        copy!(rng, data[entryname])
    catch e
        error("Error while restoring RNG state: ", e)
    end
end
