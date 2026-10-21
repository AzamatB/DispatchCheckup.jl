module DCSanitizerFixture
using CUDA

stable_device(x::Float32) = x + x

function stable_kernel!(output, input)
    i = (blockIdx().x - Int32(1)) * blockDim().x + threadIdx().x
    if i <= length(output)
        @inbounds output[i] = stable_device(input[i])
    end
    return nothing
end

# A 36-argument call exercises DispatchDoctor's device-safe wide-call check.
function wide_kernel!(output, x1, x2, x3, x4, x5, x6, x7, x8, x9,
    x10, x11, x12, x13, x14, x15, x16, x17, x18, x19, x20, x21,
    x22, x23, x24, x25, x26, x27, x28, x29, x30, x31, x32, x33, x34, x35, x36)
    output[1] = x1 + x36
    return nothing
end

@inline override_product(x::Float64, y::Float64) = x * y
CUDA.@device_override @noinline override_product(x::Float64, y::Float64) = x * y

function override_kernel!(output, x, y)
    output[1] = override_product(x, y)
    return nothing
end

function typed_val_kernel!(out, x, offset, n, ::Val{HAS_OFFSET}) where {HAS_OFFSET}
    i = (blockIdx().x - Int32(1)) * blockDim().x + threadIdx().x
    if i <= n
        @inbounds out[i] = x[i] + (HAS_OFFSET ? offset[1, i] : 0.0)
    end
    return nothing
end
end
