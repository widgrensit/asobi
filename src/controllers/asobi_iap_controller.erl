-module(asobi_iap_controller).

-export([verify_apple/1, verify_google/1]).

%% POST /api/v1/iap/apple
%% Body: {"signed_transaction": "<JWS string>"}
-spec verify_apple(cowboy_req:req()) -> {json, integer(), map(), map()}.
verify_apple(#{json := #{~"signed_transaction" := SignedTxn}} = _Req) ->
    case asobi_iap:verify_apple(SignedTxn) of
        {ok, Result} ->
            {json, 200, #{}, Result};
        {error, Reason} ->
            {json, 422, #{}, #{error => Reason}}
    end;
verify_apple(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% POST /api/v1/iap/google
%% Body: {"product_id": "...", "purchase_token": "..."}
-spec verify_google(cowboy_req:req()) -> {json, integer(), map(), map()}.
verify_google(#{json := Params} = _Req) ->
    case asobi_iap:verify_google(Params) of
        {ok, Result} ->
            {json, 200, #{}, Result};
        {error, Reason} ->
            {json, 422, #{}, #{error => Reason}}
    end;
verify_google(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.
