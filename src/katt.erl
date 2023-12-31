%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Copyright 2012- Klarna AB
%%% Copyright 2014- AUTHORS
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%% @copyright 2012- Klarna AB, AUTHORS
%%%
%%% @doc Klarna API Testing Tool
%%%
%%% Use for shooting http requests in a sequential order and verifying the
%%% response.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =======================================================
-module(katt).

%%%_* Exports ==================================================================
%% API
-export([ main/1
        , run/1
        , run/2
        , run/3
        ]).

%% Internal exports
-export([ run/4
        , make_callbacks/1
        ]).

%%%_* Includes =================================================================
-include("katt.hrl").

%%%_* Types ====================================================================
-type katt_blueprint() :: #katt_blueprint{}.
-type scenario() :: file:filename() | katt_blueprint().

%%%_* API ======================================================================

%% @doc Run from CLI with arguments.
%% @end
-spec main([string()]) -> ok | {error, katt_bare_mode}.
main(Args) ->
  katt_cli:main(Args).

%% @doc Run test scenario. Argument is the full path to the scenario file,
%% a KATT Blueprint file, or the KATT Blueprint itself.
%% @end
-spec run(scenario()) -> run_result().
run(Scenario) -> run(Scenario, []).

%% @doc Run test scenario. Argument is the full path to the scenario file,
%% a KATT Blueprint file, or the KATT Blueprint itself.
%% @end
-spec run(scenario(), params()) -> run_result().
run(Scenario, Params) -> run(Scenario, Params, []).

%% @doc Run test scenario. First argument is the full path to the scenario file,
%% a KATT Blueprint file, or the KATT Blueprint itself.
%% Second argument is a key-value list of parameters, such as hostname, port.
%% You can also pass custom variable names (atoms) and values (strings).
%% Third argument is a key-value list of custom callbacks such as a custom
%% parser to use instead of the built-in default parser (maybe_parse_body).
%% @end
-spec run(scenario(), params(), callbacks()) -> run_result().
run(Scenario, ScenarioParams, ScenarioCallbacks) ->
  Params = ordsets:from_list(make_params(ScenarioParams)),
  Callbacks = make_callbacks(ScenarioCallbacks),
  Timeout = proplists:get_value( "scenario_timeout"
                               , Params
                               ),
  ProgressFun = proplists:get_value( progress
                                   , Callbacks
                                   ),
  spawn_link(?MODULE, run, [self(), Scenario, Params, Callbacks]),
  run_loop(Timeout, ProgressFun).

%%%_* Internal exports =========================================================

%% @private
run(From, Blueprint, Params, Callbacks)
  when is_record(Blueprint, katt_blueprint) ->
  {FinalParams, TransactionResults} = run_blueprint( From
                                                   , Blueprint
                                                   , Params
                                                   , Callbacks),
  FailureFilter = fun({ _Transaction
                      , _Params
                      , _Request
                      , _Response
                      , ValidationResult }) ->
                    ValidationResult =/= pass
                  end,
  Failures = lists:filter(FailureFilter, TransactionResults),
  Status = case Failures of
             [] -> pass;
             _ -> fail
           end,
  Result = { Status
           , Blueprint#katt_blueprint.filename
           , Params
           , FinalParams
           , TransactionResults
           },
  From ! {progress, status, Status},
  From ! {done, Result};
run(From, Filename, Params, Callbacks) ->
  From ! {progress, parsing, Filename},
  {ok, Blueprint} = katt_blueprint_parse:file(Filename),
  From ! {progress, parsed, Filename},
  run(From, Blueprint#katt_blueprint{filename = Filename}, Params, Callbacks).

%% @private
make_callbacks(Callbacks) ->
  katt_util:merge_proplists([ {ext, ?DEFAULT_EXT_FUN}
                            , {parse, ?DEFAULT_PARSE_FUN}
                            , {progress, ?DEFAULT_PROGRESS_FUN}
                            , {recall, ?DEFAULT_RECALL_FUN}
                            , {request, ?DEFAULT_REQUEST_FUN}
                            , {text_diff, ?DEFAULT_TEXT_DIFF_FUN}
                            , {transform, ?DEFAULT_TRANSFORM_FUN}
                            , {validate, ?DEFAULT_VALIDATE_FUN}
                            ], Callbacks).

%%%_* Internal =================================================================

-ifdef(OTP_RELEASE). %% OTP 21+
http_uri_parse(URI) ->
  case uri_string:parse(URI) of
  URIMap when is_map(URIMap) ->
      Scheme0 = maps:get(scheme, URIMap, <<"no_scheme">>),
      Scheme = case is_binary(Scheme0) of
                 true -> binary_to_atom(Scheme0, utf8);
                 false -> list_to_atom(Scheme0)
               end,
      DefaultHost = case is_binary(URI) of
                      true -> <<>>;
                      false -> ""
                    end,
      Host = maps:get(host, URIMap, DefaultHost),
      %% port defaults as per http_uri:scheme_defaults/0
      %% see https://github.com/erlang/otp
      %% ... /blob/2831b6c/lib/inets/src/http_lib/http_uri.erl#L101-L107
      DefaultPort = case Scheme of
                      http -> 80;
                      https -> 443;
                      ftp -> 21;
                      ssh -> 22;
                      sftp -> 22;
                      tftp -> 69
                    end,
      Port = maps:get(port, URIMap, DefaultPort),
      DefaultPath = case is_binary(URI) of
                      true -> <<"/">>;
                      false -> ""
                    end,
      Path = maps:get(path, URIMap, DefaultPath),
      { ok
      , Scheme
      , Host
      , Port
      , Path
      };
  {error, Reason, _Info} ->
      {error, Reason}
  end.
-else.
http_uri_parse(URI) ->
  {ok, {Scheme, _, Host, Port, Path, _Query}} = http_uri:parse(URI),
  {ok, Scheme, Host, Port, Path}.
-endif.


run_loop(ScenarioTimeout, ProgressFun) ->
  receive
    {progress, Step, Detail} ->
      ProgressFun(Step, Detail),
      run_loop(ScenarioTimeout, ProgressFun);
    {done, Result} ->
      Result
  after ScenarioTimeout ->
      ProgressFun(status, timeout),
      {error, timeout, ScenarioTimeout}
  end.

%% Take default params, and also merge in optional params from Params, to return
%% a proplist of params.
make_params(ScenarioParams0) ->
  ScenarioParams1 = [ {katt_util:to_list(K), V} || {K, V} <- ScenarioParams0],
  BaseUrl =
    case proplists:get_value("base_url", ScenarioParams1) of
      undefined ->
        base_url_from_params(ScenarioParams1);
      BaseUrl0 ->
        BaseUrl0
    end,
  {ok, Protocol0, Hostname, Port, Path0} = http_uri_parse(BaseUrl),
  Path =
    case Path0 of
      "/" ->
        "";
      _ ->
        Path0
    end,
  Protocol = katt_util:to_list(Protocol0) ++ ":",
  BaseUrlParams = [ {"base_url", BaseUrl}
                  , {"protocol", Protocol}
                  , {"hostname", Hostname}
                  , {"port", Port}
                  , {"base_path", Path}
                  ],
  ScenarioParams2 = katt_util:merge_proplists(ScenarioParams1, BaseUrlParams),
  DefaultParams = [ {"request_timeout", ?DEFAULT_REQUEST_TIMEOUT}
                  , {"scenario_timeout", ?DEFAULT_SCENARIO_TIMEOUT}
                  ],
  katt_util:merge_proplists(DefaultParams, ScenarioParams2).

base_url_from_params(ScenarioParams) ->
  Protocol = proplists:get_value("protocol", ScenarioParams, ?DEFAULT_PROTOCOL),
  Hostname = proplists:get_value("hostname", ScenarioParams, ?DEFAULT_HOSTNAME),
  %% port defaults as per http_uri:scheme_defaults/0
  %% see https://github.com/erlang/otp
  %% ... /blob/2831b6c/lib/inets/src/http_lib/http_uri.erl#L101-L107
  DefaultPort = case Protocol of
                      "http:" -> 80;
                      "https:" -> 443;
                      "ftp:" -> 21;
                      "ssh:" -> 22;
                      "sftp:" -> 22;
                      "tftp:" -> 69
                end,
  Port = proplists:get_value("port", ScenarioParams, DefaultPort),
  BasePath = proplists:get_value( "base_path"
                                , ScenarioParams
                                , ?DEFAULT_BASE_PATH
                                ),
  Protocol ++ "//" ++ make_host(Protocol, Hostname, Port) ++ BasePath.

run_blueprint(From, Blueprint, Params, Callbacks) ->
  Result = run_transactions( From
                           , Blueprint#katt_blueprint.transactions
                           , Params
                           , Callbacks
                           , {0, []}
                           ),
  {FinalParams, {_Count, TransactionResults}} = Result,
  {FinalParams, lists:reverse(TransactionResults)}.

run_transactions( _From
                , []
                , FinalParams
                , _Callbacks
                , {Count, Results}
                ) ->
  {FinalParams, {Count, Results}};
run_transactions( From
                , [#katt_transaction{ description = Description0
                                    , params = TransactionParams
                                    , request = Req0
                                    , response = Res
                                    }|T]
                , Params0
                , Callbacks
                , {Count, Results}
                ) ->
  Params = katt_util:merge_proplists(Params0, TransactionParams),
  Hdrs0 = Req0#katt_request.headers,
  Description = case proplists:get_value("x-katt-description", Hdrs0) of
                  undefined ->
                    case Description0 of
                      <<>> ->
                        "Transaction " ++ integer_to_list(Count);
                      _ ->
                        Description0
                    end;
                  Description1 ->
                    Description1
                end,
  Hdrs = proplists:delete("x-katt-description", Hdrs0),
  Req = Req0#katt_request{headers = Hdrs},
  From ! {progress, run_transaction, Description},
  Request = make_katt_request(Req, Params, Callbacks),
  RequestFun = proplists:get_value(request, Callbacks),
  ValidateFun = proplists:get_value(validate, Callbacks),
  ActualResponse0 = RequestFun(Request, Params, Callbacks),
  ActualResponseHdrs = ActualResponse0#katt_response.headers,
  {_ActualResponseContentType, _ActualResponseHdrs, ActualResponseHdrsCT} =
    get_headers_content_type(Res#katt_response.headers, ActualResponseHdrs),
  ParseFun = proplists:get_value(parse, Callbacks),
  ActualResponseParsedBody = ParseFun( ActualResponseHdrsCT
                                     , ActualResponse0#katt_response.body
                                     , Params
                                     , Callbacks
                                     ),
  ActualResponse =
    ActualResponse0#katt_response{parsed_body = ActualResponseParsedBody},
  ExpectedResponse = make_katt_response(ActualResponse, Res, Params, Callbacks),
  ValidationResult = ValidateFun( ExpectedResponse
                                , ActualResponse
                                , Params
                                , Callbacks
                                ),
  case ValidationResult of
    {pass, AddParams} ->
      Result = { Description
               , Params
               , Request
               , ActualResponse
               , pass
               },
      From ! {progress, transaction_result, Result},
      NextParams = katt_util:merge_proplists(Params, AddParams),
      run_transactions( From
                      , T
                      , NextParams
                      , Callbacks
                      , {Count + 1, [Result|Results]}
                      );
    _                 ->
      Result = { Description
               , Params
               , Request
               , ActualResponse
               , ValidationResult
               },
      From ! {progress, transaction_result, Result},
      {Params, {Count + 1, [Result|Results]}}
  end.

make_katt_request( #katt_request{url=Url0, headers=Hdrs0, body=Body0} = Req0
                 , Params
                 , Callbacks
                 ) ->
  RecallFun = proplists:get_value(recall, Callbacks),
  Url1 = katt_util:from_utf8(
           RecallFun( url
                    , katt_util:to_utf8(Url0)
                    , Params
                    , Callbacks
                    )),
  Url = make_request_url(Url1, Params),
  Hdrs1 = RecallFun(headers, Hdrs0, Params, Callbacks),
  {_ContentType, Hdrs, HdrsCT} = get_headers_content_type(Hdrs1),
  [HdrsCT, Body] = RecallFun(body, [HdrsCT, Body0], Params, Callbacks),
  ParseFun = proplists:get_value(parse, Callbacks),
  ParsedBody = ParseFun( HdrsCT
                       , Body
                       , Params
                       , Callbacks
                       ),
  Req = Req0#katt_request{ url = Url
                         , headers = Hdrs
                         , body = Body
                         , parsed_body = ParsedBody
                         },
  maybe_transform_request(Req, Params, Callbacks).

make_katt_response( ActualResponse
                  , #katt_response{headers=Hdrs0, body=Body0} = Res0
                  , Params
                  , Callbacks
                  ) ->
  RecallFun = proplists:get_value(recall, Callbacks),
  ParseFun = proplists:get_value(parse, Callbacks),
  Hdrs1 = RecallFun(headers, Hdrs0, Params, Callbacks),
  {_ContentType, Hdrs, HdrsCT} = get_headers_content_type(Hdrs1),
  [HdrsCT, Body] = RecallFun(body, [HdrsCT, Body0], Params, Callbacks),
  ParsedBody = ParseFun(HdrsCT, Body, Params, Callbacks),
  Res = Res0#katt_response{ headers = Hdrs
                          , body = Body
                          , parsed_body = ParsedBody
                          },
  maybe_transform_response(Res, Params, Callbacks, ActualResponse).

-spec make_request_url( string()
                      , params()
                      ) -> nonempty_string().
make_request_url(Url = "http://" ++ _, _Params) -> Url;
make_request_url(Url = "https://" ++ _, _Params) -> Url;
make_request_url(Path, Params) ->
  Protocol = proplists:get_value("protocol", Params),
  Hostname = proplists:get_value("hostname", Params),
  Port = proplists:get_value("port", Params),
  BasePath = proplists:get_value("base_path", Params, ""),
  string:join([ Protocol
              , "//"
              , make_host(Protocol, Hostname, Port)
              , BasePath
              , Path
              ], "").

make_host("http:", Hostname, 80) -> Hostname;
make_host("https:", Hostname, 443) -> Hostname;
make_host(_Proto, Hostname, Port) ->
  Hostname ++ ":" ++ katt_util:to_list(Port).

maybe_transform_request(Req0, Params, Callbacks) ->
  Hdrs0 = Req0#katt_request.headers,
  case proplists:get_value("x-katt-transform", Hdrs0) of
    undefined ->
      Req0;
    TransformId ->
      TransformFun = proplists:get_value(transform, Callbacks),
      Hdrs = proplists:delete("x-katt-transform", Hdrs0),
      Req = Req0#katt_request{headers = Hdrs},
      TransformFun(TransformId, Req, Params, Callbacks)
  end.

maybe_transform_response(Res0, Params, Callbacks, ActualResponse) ->
  Hdrs0 = Res0#katt_response.headers,
  case proplists:get_value("x-katt-transform", Hdrs0) of
    undefined ->
      Res0;
    TransformId ->
      TransformFun = proplists:get_value(transform, Callbacks),
      Hdrs = proplists:delete("x-katt-transform", Hdrs0),
      Res = Res0#katt_response{headers = Hdrs},
      TransformFun(TransformId, {Res, ActualResponse}, Params, Callbacks)
  end.

get_headers_content_type(Hdrs) ->
  get_headers_content_type(Hdrs, Hdrs).

get_headers_content_type(HdrsSrc, HdrsTarget0) ->
  case proplists:get_value("x-katt-content-type", HdrsSrc) of
    undefined ->
      {undefined, HdrsTarget0, HdrsTarget0};
    ContentType ->
      HdrsTarget = proplists:delete("x-katt-content-type", HdrsTarget0),
      HdrsTargetCT = case proplists:is_defined("Content-Type", HdrsTarget) of
                       true ->
                         katt_util:merge_proplists( HdrsTarget
                                                  , [{ "Content-Type"
                                                     , ContentType
                                                     }]);
                       false ->
                         katt_util:merge_proplists( HdrsTarget
                                                  , [{ "content-type"
                                                     , ContentType
                                                     }])
                     end,
      {ContentType, HdrsTarget, HdrsTargetCT}
  end.
