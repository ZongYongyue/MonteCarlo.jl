function default_measurements(mc::DQMC, model)
    Dict(
        :conf => ConfigurationMeasurement(mc, model),
        :Greens => GreensMeasurement(mc, model),
        :BosonEnergy => BosonEnergyMeasurement(mc, model)
    )
end



################################################################################
### General DQMC Measurements
################################################################################



"""
    GreensMeasurement(mc::DQMC, model)

Measures the equal time Greens function of the given DQMC simulation and model.

The mean of this measurement corresponds to the expectation value of the Greens
function for the full partition function, i.e. including fermionic and bosonic
(auxiliary field) degrees of freedom.
"""
struct GreensMeasurement{OT <: AbstractObservable} <: AbstractMeasurement
    obs::OT
end
function GreensMeasurement(mc::DQMC, model)
    o = LightObservable(
        LogBinner(zeros(eltype(mc.s.greens), size(mc.s.greens))),
        "Equal-times Green's function",
        "Observables.jld",
        "G"
    )
    GreensMeasurement{typeof(o)}(o)
end
@bm function measure!(m::GreensMeasurement, mc::DQMC, model, i::Int64)
    push!(m.obs, greens(mc))
end
function save_measurement(file::JLD.JldFile, m::GreensMeasurement, entryname::String)
    write(file, entryname * "/VERSION", 1)
    write(file, entryname * "/type", typeof(m))
    write(file, entryname * "/obs", m.obs)
    nothing
end
function load_measurement(data, ::Type{T}) where T <: GreensMeasurement
    @assert data["VERSION"] == 1
    data["type"](data["obs"])
end


"""
    BosonEnergyMeasurement(mc::DQMC, model)

Measures the bosnic energy of the given DQMC simulation and model.

Note that this measurement requires `energy_boson(mc, model, conf)` to be
implemented for the specific `model`.
"""
struct BosonEnergyMeasurement{OT <: AbstractObservable} <: AbstractMeasurement
    obs::OT
end
function BosonEnergyMeasurement(mc::DQMC, model)
    o = LightObservable(Float64, name="Bosonic Energy", alloc=1_000_000)
    BosonEnergyMeasurement{typeof(o)}(o)
end
@bm function measure!(m::BosonEnergyMeasurement, mc::DQMC, model, i::Int64)
    push!(m.obs, energy_boson(mc, model, conf(mc)))
end
function save_measurement(file::JLD.JldFile, m::BosonEnergyMeasurement, entryname::String)
    write(file, entryname * "/VERSION", 1)
    write(file, entryname * "/type", typeof(m))
    write(file, entryname * "/obs", m.obs)
    nothing
end
function load_measurement(data, ::Type{T}) where T <: BosonEnergyMeasurement
    @assert data["VERSION"] == 1
    data["type"](data["obs"])
end



################################################################################
### Utility
################################################################################



_get_shape(model) = (nsites(model),)
_get_shape(mask::RawMask) = (mask.nsites, mask.nsites)
_get_shape(mask::DistanceMask) = (size(mask.targets, 2),)

function mask_kernel!(mask::RawMask, IG, G, kernel::Function, output)
    for i in 1:mask.nsites
        for j in 1:mask.nsites
            output[i, j] = kernel(IG, G, i, j)
        end
    end
    output
end
function mask_kernel!(mask::DistanceMask, IG, G, kernel::Function, output)
    output .= zero(eltype(output))
    for i in 1:size(mask.targets, 1)
        for (delta, j) in enumerate(mask[i, :])
            output[delta] += kernel(IG, G, i, j)
        end
    end
    output
end



################################################################################
### Spin 1/2 Measurements
################################################################################



abstract type SpinOneHalfMeasurement <: AbstractMeasurement end

# Abuse prepare! to verify requirements
function prepare!(m::SpinOneHalfMeasurement, mc::DQMC, model)
    model.flv != 2 && throw(AssertionError(
        "A spin 1/2 measurement ($(typeof(m))) requires two (spin) flavors of fermions, but " *
        "the given model has $(model.flv)."
    ))
end


@doc raw"""
    ChargeDensityCorrelationMeasurement(mc::DQMC, model)

Measures the fermionic expectation value of the charge density correlation
matrix `⟨nᵢnⱼ⟩`.

The mean of this measurement corresponds to the expectation value of the charge
density correlation matrix for the full partition function, i.e. including
fermionic and bosonic (auxiliary field) degrees of freedom.
"""
struct ChargeDensityCorrelationMeasurement{
        OT <: AbstractObservable,
        AT <: Array,
        MT <: AbstractMask
    } <: SpinOneHalfMeasurement
    obs::OT
    temp::AT
    mask::MT
end
function ChargeDensityCorrelationMeasurement(mc::DQMC, model; mask=RawMask(lattice(model)))
    N = nsites(model)
    T = eltype(mc.s.greens)
    obs = LightObservable(
        LogBinner(zeros(T, _get_shape(mask))),
        "Charge density wave correlations", "Observables.jld", "CDC"
    )
    temp = zeros(T, _get_shape(mask))
    ChargeDensityCorrelationMeasurement(obs, temp, mask)
end
function measure!(m::ChargeDensityCorrelationMeasurement, mc::DQMC, model, i::Int64)
    N = nsites(model)
    G = greens(mc, model)
    IG = I - G

    mask_kernel!(m.mask, IG, G, _cdc_kernel, m.temp)

    push!(m.obs, m.temp / N)
end
function _cdc_kernel(IG, G, i, j)
    # TODO pass N?
    N = div(size(IG, 1), 2)
    # ⟨n↑n↑⟩
    IG[i, i] * IG[j, j] +
    IG[j, i] *  G[i, j] +
    # ⟨n↑n↓⟩
    IG[i, i] * IG[j + N, j + N] +
    IG[j + N, i] *  G[i, j + N] +
    # ⟨n↓n↑⟩
    IG[i + N, i + N] * IG[j, j] +
    IG[j, i + N] *  G[i + N, j] +
    # ⟨n↓n↓⟩
    IG[i + N, i + N] * IG[j + N, j + N] +
    IG[j + N, i + N] *  G[i + N, j + N]
end



"""
    MagnetizationMeasurement(mc::DQMC, model)

Measures the fermionic expectation value of the magnetization
`M_x = ⟨c_{i, ↑}^† c_{i, ↓} + h.c.⟩` in x-,
`M_y = -i⟨c_{i, ↑}^† c_{i, ↓} - h.c.⟩` in y- and
`M_z = ⟨n_{i, ↑} - n_{i, ↓}⟩` in z-direction.

The mean of this measurement corresponds to the expectation value of the x/y/z
magnetization for the full partition function, i.e. including fermionic and
bosonic (auxiliary field) degrees of freedom.

Note:

The Magnetization in x/y/z direction can be accessed via fields `x`, `y` and `z`.
"""
struct MagnetizationMeasurement{
        OTx <: AbstractObservable,
        OTy <: AbstractObservable,
        OTz <: AbstractObservable,
        AT <: AbstractArray
    } <: SpinOneHalfMeasurement

    x::OTx
    y::OTy
    z::OTz
    temp::AT
end
function MagnetizationMeasurement(mc::DQMC, model)
    N = nsites(model)
    T = eltype(mc.s.greens)
    Ty = T <: Complex ? T : Complex{T}

    # Magnetizations
    m1x = LightObservable(
        LogBinner([zero(T) for _ in 1:N]),
        "Magnetization x", "Observables.jld", "Mx"
    )
    m1y = LightObservable(
        LogBinner([zero(Ty) for _ in 1:N]),
        "Magnetization y", "Observables.jld", "My"
    )
    m1z = LightObservable(
        LogBinner([zero(T) for _ in 1:N]),
        "Magnetization z", "Observables.jld", "Mz"
    )

    MagnetizationMeasurement(m1x, m1y, m1z, [zero(T) for _ in 1:N])
end
function measure!(m::MagnetizationMeasurement, mc::DQMC, model, i::Int64)
    N = nsites(model)
    G = greens(mc, model)
    IG = I - G

    # G[1:N,    1:N]    up -> up section
    # G[N+1:N,  1:N]    down -> up section
    # ...
    # G[i, j] = c_i c_j^†

    # Magnetization
    # c_{i, up}^† c_{i, down} + c_{i, down}^† c_{i, up}
    # mx = [- G[i+N, i] - G[i, i+N]           for i in 1:N]
    map!(i -> -G[i+N, i] - G[i, i+N], m.temp, 1:N)
    push!(m.x, m.temp)

    # -i [c_{i, up}^† c_{i, down} - c_{i, down}^† c_{i, up}]
    # my = [-1im * (G[i, i+N] - G[i+N, i])    for i in 1:N]
    map!(i -> -1im *(G[i+N, i] - G[i, i+N]), m.temp, 1:N)
    push!(m.y, m.temp)
    # c_{i, up}^† c_{i, up} - c_{i, down}^† c_{i, down}
    # mz = [G[i+N, i+N] - G[i, i]             for i in 1:N]
    map!(i -> G[i+N, i+N] - G[i, i], m.temp, 1:N)
    push!(m.z, m.temp)
end



"""
    SpinDensityCorrelationMeasurement(mc::DQMC, model)

Measures the fermionic expectation value of the spin density correlation matrix
`SDC_x = ⟨(c_{i, ↑}^† c_{i, ↓} + h.c.) (c_{j, ↑}^† c_{j, ↓} + h.c.)⟩` in x-,
`SDC_y = -⟨(c_{i, ↑}^† c_{i, ↓} - h.c.) (c_{j, ↑}^† c_{j, ↓} - h.c.)⟩` in y- and
`SDC_z = ⟨(n_{i, ↑} - n_{i, ↓}) (n_{j, ↑} - n_{j, ↓})⟩` in z-direction.

The mean of this measurement corresponds to the expectation value of the x/y/z
spin density correlation matrix for the full partition function, i.e. including
fermionic and bosonic (auxiliary field) degrees of freedom.

Note:

The spin density correlation matrix in x/y/z direction can be accessed via fields `x`,
`y` and `z`.
"""
struct SpinDensityCorrelationMeasurement{
        OTx <: AbstractObservable,
        OTy <: AbstractObservable,
        OTz <: AbstractObservable,
        AT <: Array,
        MT <: AbstractMask
    } <: SpinOneHalfMeasurement

    x::OTx
    y::OTy
    z::OTz
    temp::AT
    mask::MT
end
function SpinDensityCorrelationMeasurement(mc::DQMC, model; mask=RawMask(lattice(model)))
    N = nsites(model)
    T = eltype(mc.s.greens)
    Ty = T <: Complex ? T : Complex{T}

    # Spin density correlation
    sdc2x = LightObservable(
        LogBinner(zeros(T, _get_shape(mask))),
        "Spin Density Correlation x", "Observables.jld", "sdc-x"
    )
    sdc2y = LightObservable(
        LogBinner(zeros(Ty, _get_shape(mask))),
        "Spin Density Correlation y", "Observables.jld", "sdc-y"
    )
    sdc2z = LightObservable(
        LogBinner(zeros(T, _get_shape(mask))),
        "Spin Density Correlation z", "Observables.jld", "sdc-z"
    )
    temp = zeros(T, _get_shape(mask))
    SpinDensityCorrelationMeasurement(sdc2x, sdc2y, sdc2z, temp, mask)
end
function measure!(m::SpinDensityCorrelationMeasurement, mc::DQMC, model, i::Int64)
    N = nsites(model)
    G = greens(mc, model)
    IG = I - G

    # G[1:N,    1:N]    up -> up section
    # G[N+1:N,  1:N]    down -> up section
    # ...
    # G[i, j] = c_i c_j^†


    # Spin Density Correlation
    mask_kernel!(m.mask, IG, G, _sdc_x_kernel, m.temp)
    push!(m.x, m.temp / N)

    mask_kernel!(m.mask, IG, G, _sdc_y_kernel, m.temp)
    push!(m.y, m.temp / N)

    mask_kernel!(m.mask, IG, G, _sdc_z_kernel, m.temp)
    push!(m.z, m.temp / N)
end
function _sdc_x_kernel(IG, G, i, j)
    N = div(size(IG, 1), 2)
    IG[i+N, i] * IG[j+N, j] + IG[j+N, i] * G[i+N, j] +
    IG[i+N, i] * IG[j, j+N] + IG[j, i] * G[i+N, j+N] +
    IG[i, i+N] * IG[j+N, j] + IG[j+N, i+N] * G[i, j] +
    IG[i, i+N] * IG[j, j+N] + IG[j, i+N] * G[i, j+N]
end
function _sdc_y_kernel(IG, G, i, j)
    N = div(size(IG, 1), 2)
    - IG[i+N, i] * IG[j+N, j] - IG[j+N, i] * G[i+N, j] +
      IG[i+N, i] * IG[j, j+N] + IG[j, i] * G[i+N, j+N] +
      IG[i, i+N] * IG[j+N, j] + IG[j+N, i+N] * G[i, j] -
      IG[i, i+N] * IG[j, j+N] - IG[j, i+N] * G[i, j+N]
end
function _sdc_z_kernel(IG, G, i, j)
    N = div(size(IG, 1), 2)
    IG[i, i] * IG[j, j] + IG[j, i] * G[i, j] -
    IG[i, i] * IG[j+N, j+N] - IG[j+N, i] * G[i, j+N] -
    IG[i+N, i+N] * IG[j, j] - IG[j, i+N] * G[i+N, j] +
    IG[i+N, i+N] * IG[j+N, j+N] + IG[j+N, i+N] * G[i+N, j+N]
end



"""
    PairingCorrelationMeasurement(mc::DQMC, model)

Measures the fermionic expectation value of the s-wave pairing correlation.

We define `Δᵢ = c_{i, ↑} c_{i, ↓}` s the pair-field operator and `Pᵢⱼ = ⟨ΔᵢΔⱼ^†⟩`
as the s-wave pairing correlation matrix. `Pᵢⱼ` can be accesed via the field
`mat` and its site-average via the field `uniform_fourier`.
"""
struct PairingCorrelationMeasurement{
        OT <: AbstractObservable,
        AT <: Array,
        MT <: AbstractMask
    } <: SpinOneHalfMeasurement
    obs::OT
    temp::AT
    mask::MT
end
function PairingCorrelationMeasurement(mc::DQMC, model; mask=RawMask(lattice(model)))
    T = eltype(mc.s.greens)
    N = nsites(model)

    obs1 = LightObservable(
        LogBinner(zeros(T, _get_shape(mask))),
        "Equal time pairing correlation matrix (s-wave)",
        "observables.jld",
        "etpc-s"
    )
    temp = zeros(T, _get_shape(mask))
    PairingCorrelationMeasurement(obs1, temp, mask)
end
function measure!(m::PairingCorrelationMeasurement, mc::DQMC, model, i::Int64)
    G = greens(mc, model)
    N = nsites(model)
    # Pᵢⱼ = ⟨ΔᵢΔⱼ^†⟩
    #     = ⟨c_{i, ↑} c_{i, ↓} c_{j, ↓}^† c_{j, ↑}^†⟩
    #     = ⟨c_{i, ↑} c_{j, ↑}^†⟩ ⟨c_{i, ↓} c_{j, ↓}^†⟩ -
    #       ⟨c_{i, ↑} c_{j, ↓}^†⟩ ⟨c_{i, ↓} c_{j, ↑}^†⟩
    # m.temp .= G[1:N, 1:N] .* G[N+1:2N, N+1:2N] - G[1:N, N+1:2N] .* G[N+1:2N, 1:N]

    # Doesn't require IG
    mask_kernel!(m.mask, G, G, _pc_s_wave_kernel, m.temp)
    push!(m.obs, m.temp / N)
end
function _pc_s_wave_kernel(IG, G, i, j)
    N = div(size(IG, 1), 2)
    G[i, j] * G[i+N, j+N] - G[i, j+N] * G[i+N, j]
end

"""
    uniform_fourier(M, dqmc)
    uniform_fourier(M, N)

Computes the uniform Fourier transform of matrix `M` in a system with `N` sites.
"""
uniform_fourier(M::AbstractArray, mc::DQMC) = sum(M) / nsites(mc.model)
uniform_fourier(M::AbstractArray, N::Integer) = sum(M) / N


struct UniformFourierWrapped{T <: AbstractObservable}
    obs::T
end
"""
    uniform_fourier(m::AbstractMeasurement[, field::Symbol])
    uniform_fourier(obs::AbstractObservable)

Wraps an observable with a `UniformFourierWrapped`.
Calling `mean` (`var`, etc) on a wrapped observable returns the `mean` (`var`,
etc) of the uniform Fourier transform of that observable.

`mean(uniform_fourier(m))` is equivalent to
`uniform_fourier(mean(m.obs), nsites(model))` where `obs` may differ between
measurements.
"""
uniform_fourier(m::PairingCorrelationMeasurement) = UniformFourierWrapped(m.obs)
uniform_fourier(m::ChargeDensityCorrelationMeasurement) = UniformFourierWrapped(m.obs)
function uniform_fourier(m::AbstractMeasurement, field::Symbol)
    UniformFourierWrapped(getfield(m, field))
end
uniform_fourier(obs::AbstractObservable) = UniformFourierWrapped(obs)

# Wrappers for Statistics functions
MonteCarloObservable.mean(x::UniformFourierWrapped) = _uniform_fourier(mean(x.obs))
MonteCarloObservable.var(x::UniformFourierWrapped) = _uniform_fourier(var(x.obs))
MonteCarloObservable.varN(x::UniformFourierWrapped) = _uniform_fourier(varN(x.obs))
MonteCarloObservable.std(x::UniformFourierWrapped) = _uniform_fourier(std(x.obs))
MonteCarloObservable.std_error(x::UniformFourierWrapped) = _uniform_fourier(std_error(x.obs))
MonteCarloObservable.all_vars(x::UniformFourierWrapped) = _uniform_fourier.(all_vars(x.obs))
MonteCarloObservable.all_varNs(x::UniformFourierWrapped) = _uniform_fourier.(all_varNs(x.obs))
# Autocorrelation time should not be averaged...
MonteCarloObservable.tau(x::UniformFourierWrapped) = maximum(tau(x.obs))
MonteCarloObservable.all_taus(x::UniformFourierWrapped) = maximum.(all_varNs(x.obs))
_uniform_fourier(M::AbstractArray) = sum(M) / length(M)
