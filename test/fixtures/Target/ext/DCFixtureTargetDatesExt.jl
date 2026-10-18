module DCFixtureTargetDatesExt

using DCFixtureTarget, Dates

DCFixtureTarget.extension_value(value::Date) = year(value)
ext_unstable(x::Int) = x > 0 ? x : Float64(x)

module Nested
    nested_ext_unstable(x::Int) = x > 0 ? x : Float64(x)
end

end
