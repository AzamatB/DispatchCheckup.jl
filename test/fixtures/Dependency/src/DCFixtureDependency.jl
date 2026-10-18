module DCFixtureDependency

struct Token
    value::Int
end

dependency_unstable(x::Int) = x > 0 ? x : Float64(x)

end
