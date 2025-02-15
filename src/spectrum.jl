using AbstractFFTs: fftfreq, rfftfreq
using SpecialFunctions: besselj0

abstract type StructureFactor end
abstract type Correlator end

# define concrete data types of abstract data types.
struct IsotropicStructureFactor <: StructureFactor
   D  :: Integer #dimensions
   L  :: Float64
   Δk :: Float64
   k  :: Vector{Float64}
   sk :: Vector{Float64}
end

# define constructors for the structs.
function IsotropicStructureFactor(N, D; L = 2π)
   Δk = 2π / L
   k  = @. Δk * LinRange(0, N, N + 1)
   sk = zeros(N + 1)
   return IsotropicStructureFactor(D, L, Δk, k, sk)
end

# define concrete data types of abstract data types.
struct IsotropicAutoCorrelator <: Correlator
   D  :: Integer
   r  :: Vector{Float64}
   cr :: Vector{Float64}
end

# define constructors for the structs.
function IsotropicAutoCorrelator(N, D; L = π)
   r  = LinRange(0, L, N + 1)
   cr = zeros(N + 1)
   return IsotropicAutoCorrelator(D, r, cr)
end

# Returns the magnitude of the largest wavenumber for the range kiter.
# (r)fftfreq omits the largest possible wavenumber so we add one.
@inline function _kmax(kiter)
   kmax = maximum(kiter) .+ 1
   return round(Int, hypot(kmax...)) + 1
end

# function calculate kspace points in (1D,2D,3D) given if the input data is real or complex
function _kgrid(nx::T, xfftfreq::Function) where {T<:Integer}
   return Iterators.product(xfftfreq(nx))
end

function _kgrid(nx::T, ny::T, xfftfreq::Function) where {T<:Integer}
   return Iterators.product(xfftfreq(nx), fftfreq(ny, ny))
end

function _kgrid(nx::T, ny::T, nz::T, xfftfreq::Function) where {T<:Integer}
   return Iterators.product(xfftfreq(nx), fftfreq(ny, ny), fftfreq(nz, nz))
end

@inline function _kbin(k::Tuple{Vararg{T}}) where {T<:Real}
   return round(Int, hypot(k...)) + 1
end

# Computes the structure factor S(k) given the fourier transform uk = ⨏(u) of the data.
# TODO: Write documentation.
# The internals differ slightly for a real u and a complex u.

# function to scale k₀ and kₙ if the data is real
function _scale(uk::Array{ComplexF64}, factor)
   uk0 = selectdim(uk, 1, 1)
   ukN = selectdim(uk, 1, size(uk)[1])
   @. uk0 = factor * uk0
   @. ukN = factor * ukN
end

# function to calculate structure_factor given FFT of data uk
# calculating s(k) = |uₖ|² and binning in k values
function structure_factor!(S::IsotropicStructureFactor, kiter::Iterators.ProductIterator, uk::Array{ComplexF64}, norm; isreal = true, preserve = true)
   isreal ? _scale(uk, sqrt(0.5)) : nothing

   @inbounds for (i, k) in enumerate(kiter)
      kb = _kbin(k)
      S.sk[kb] = S.sk[kb] + abs2(uk[i])
   end
   # @. S.sk = norm * S.sk
   (isreal & preserve) ? _scale(uk, 1/sqrt(0.5)) : nothing
   return nothing
end

function budget!( S::IsotropicStructureFactor, kiter::Iterators.ProductIterator, uk::Array{ComplexF64}, vk::Array{ComplexF64}, norm; isreal = true, preserve = true)
   isreal ? _scale(uk, 0.5) : nothing
   @inbounds for (i, k) in enumerate(kiter)
      kb = _kbin(k)
      S.sk[kb] = S.sk[kb] + real(conj(uk[i])*vk[i])
   end
   @. S.sk = norm * S.sk
   (isreal & preserve) ? _scale(uk, 1/0.5) : nothing
   return nothing
end

# function calculate kspace points depending upon if the input data is real or complex
_xfftfreq(nx, ::Val{true})  = rfftfreq(2 * (nx - 1), 2 * (nx - 1))
_xfftfreq(nx, ::Val{false}) = fftfreq(nx, nx)

# function calculate normalization constant depending upon if the input data is real or complex
_normalization(N, ::Val{true})  = 1.0 / (2 * (N[1] - 1) * prod(N[2:end]))^2
_normalization(N, ::Val{false}) = 1.0 / (2.0 * prod(N)^2)

# set up kgrid, normalization constant and initialize IsotropicStructureFactor (S)
function _setup(N::Tuple{Vararg{Int}}; isreal = true, L = 2π)
   kiter = _kgrid(N..., ((nx) -> _xfftfreq(nx, Val(isreal))))
   S = IsotropicStructureFactor(_kmax(kiter), length(N); L = L)
   return kiter, _normalization(N, Val(isreal)), S
end

# main functions
"""
$(TYPEDSIGNATURES) 
calculate isotropic structure factor for given `uk ≡ fft(data)` \\
Args:\\

   - `uk::Array{ComplexF64}` [Fourier transformed Array of input data. 1D, 2D or 3D arrays]\\
   - `preserve = true` [will be depricated. if `true` prevents mutation of input data]\\
   - `isreal = true` [read the note below]\\
   - `kwargs...` [accepts, `L` size of the box, default is `2π`]\\

!!! note
    - use `true`  if `data` is real and `uk = rrft(data)`\\
    - use `false` if `data` is real but `uk = fft(data)`, this use full range of fourier modes and expensive.\\
    - use `false` if `data` is complex and `uk = fft(data)`\\
"""
function isotropic_structure_factor(uk::Array{ComplexF64}; preserve = true, isreal = true, kwargs...)
   kiter, norm, S = _setup(size(uk); isreal, kwargs...)
   structure_factor!(S, kiter, uk, norm; isreal, preserve)
   @. S.sk = norm * S.sk
   return S
end
"""
$(TYPEDSIGNATURES) 
calculate isotropic structure factor for given `uk = fft(data)` \\
Args:\\

   - `uk::Tuple{Vararg{Array{ComplexF64}}}`\\

Takes tuple of Fourier transformed Array of input data. (1D, 2D or 3D arrays). Useful for a vectorial field.\\
effectively Calculates `|uₖ|² + |vₖ|²` where `u` and `v` are components of vectorial field.
"""
function isotropic_structure_factor(uk::Tuple{Vararg{Array{ComplexF64}}}; preserve = true, isreal = true, kwargs...)
   kiter, norm, S = _setup(size(uk[1]); isreal, kwargs...)
   for uki in uk
      structure_factor!(S, kiter, uki, norm; isreal, preserve)
   end
   @. S.sk = norm * S.sk
   return S
end

function budget(uk::Array{ComplexF64}, vk::Array{ComplexF64}; preserve = true, isreal = true, kwargs...)
   size(uk) == size(vk) || throw(DimensionMismatch(
      "size(uk) = $(size(uk)) should be identical to size(vk) = $(size(vk))"
   ))
   kiter, norm, S = _setup(size(uk); isreal, kwargs...)
   budget!(S, kiter, uk, vk, norm; isreal, preserve)
   return S
end

@inline _expintegral(kr, ::Val{1}) = cos(kr)
@inline _expintegral(kr, ::Val{2}) = besselj0(kr)
@inline _expintegral(kr, ::Val{3}) = sinc(kr/π)

"""
$(TYPEDSIGNATURES) 
Calculates isotropic correlation function `C(r) = ⟨u(0)u(r)⟩` given isotropic structure function `S(k)`\\
Args:\\

   - `S::IsotropicStructureFactor` [StructureFactor object from [`isotropic_structure_factor`](@ref) function]\\
   - `N = 128` [number of discrete `r` points for `C(r)`, keep it below the box size, Nyquist theorem]

"""
function correlation(S::IsotropicStructureFactor; N = 128)
   C = IsotropicAutoCorrelator(N, S.D; L = S.L / 2)
   @inbounds for (i, r) in enumerate(C.r)
      C.cr[i] = sum((@. S.sk * _expintegral(S.k * r, Val(S.D))))
   end
   @. C.cr = C.cr / C.cr[1]
   return C
end
