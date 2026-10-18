module DCFixtureConsumer

import DCFixtureTarget

token_type() = DCFixtureTarget.Token
make_token(x::Int) = DCFixtureTarget.token(x)

end
