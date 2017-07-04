-file("pulse_otp-1.41.2/src/pulse_gen_event.erl", 0).
-module(pulse_gen_event).

-export([compiled/0]).
-compile({parse_transform, pulse_instrument}).
-include("../include/pulse_otp.hrl").

-ifdef(OTP_R17).
-include("pulse_gen_event_r17.erl").

-else.
-ifdef(OTP_R18).
-include("pulse_gen_event_r18.erl").

-else.
-ifdef(OTP_R19).
-include("pulse_gen_event_r19.erl").

-else.
-ifdef(OTP_R20).
-include("pulse_gen_event_r19.erl").

-else.
-error("Unsupported OTP release").
-endif.
-endif.
-endif.
-endif.

compiled() -> ?COMPILED.


