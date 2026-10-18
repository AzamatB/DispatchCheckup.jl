module DCFixtureSkipped

stable(x::Int) = x + 1
function callback_factory(offset::Int)
    return x -> x > offset ? x : Float64(x)
end
const callback = callback_factory(0)

end
