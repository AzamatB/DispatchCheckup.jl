module DCFixtureGPU

using CUDA

stable_device(x::Float32) = x + x
unstable_device(x::Int32) = x > Int32(0) ? x : Float32(x)

function stable_kernel!(output, input)
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    if index <= length(output)
        @inbounds output[index] = stable_device(input[index])
    end
    return nothing
end

function unstable_kernel!(output, input)
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    if index <= length(output)
        @inbounds output[index] = Float32(unstable_device(input[index]))
    end
    return nothing
end

# Wide argument lists must not introduce a host-side tuple map in the checker.
function wide_kernel!(output, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18, x19, x20, x21, x22, x23, x24, x25, x26, x27, x28, x29, x30, x31, x32, x33, x34, x35, x36)
    output[1] = x1 + x36
    return nothing
end

@inline override_product(x::Float64, y::Float64) = x * y
CUDA.@device_override @noinline override_product(x::Float64, y::Float64) = x * y

function override_kernel!(output, x, y)
    output[1] = override_product(x, y)
    return nothing
end

end
