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

end
