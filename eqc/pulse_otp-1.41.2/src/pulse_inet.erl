-file("pulse_otp-1.41.2/src/pulse_inet.erl", 0).
-module(pulse_inet).

-export([compiled/0]).
-compile({parse_transform, pulse_instrument}).
-include("../include/pulse_otp.hrl").
-compile({pulse_replace_module, [{inet,     pulse_inet},
                                 {inet_tcp, pulse_inet_tcp},
                                 {gen_tcp,  pulse_gen_tcp}]}).

-ifdef(OTP_R17).
-include("pulse_inet_r17.erl").

-else.
-ifdef(OTP_R18).
-include("pulse_inet_r18.erl").

-else.
-ifdef(OTP_R19).
-include("pulse_inet_r19.erl").

-else.
-ifdef(OTP_R20).
-include("pulse_inet_r19.erl").

-else.
-error("Unsupported OTP release").
-endif.
-endif.
-endif.
-endif.

compiled() -> ?COMPILED.


