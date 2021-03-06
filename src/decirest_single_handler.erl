-module(decirest_single_handler).
-export([
  init/2,
  is_authorized/2,
  is_authorized_default/2,
  forbidden/2,
  forbidden_default/2,
  allowed_methods/2,
  allowed_methods_default/2,
  options/2,
  content_types_accepted/2,
  content_types_accepted_default/2,
  from_fun/2,
  from_fun_default/2,
  content_types_provided/2,
  content_types_provided_default/2,
  to_fun/2,
  to_fun_default/2,
  to_html/2,
  to_html_default/2,
  to_json/2,
  to_json_default/2,
  delete_resource/2,
  delete_resource_default/2,
  resource_exists/2,
  resource_exists_default/2
]).

-spec init(_,map()) -> {'cowboy_rest',_,#{'rstate':=#{}, _=>_}}.
init(Req, State = #{module := Module}) ->
  decirest:apply_with_default(Module, init, [Req, State], fun init_default/2).

init_default(Req, State) ->
  {cowboy_rest, Req#{bindings => decirest_query:get_bindings(Req, State)}, State#{rstate => #{}}}.

-spec is_authorized(_,#{'module':=atom(), _=>_}) -> any().
is_authorized(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, is_authorized, Req, State, fun is_authorized_default/2).

-spec is_authorized_default(_,_) -> any().
is_authorized_default(Req, State) ->
  decirest_auth:is_authorized(Req, State).

-spec forbidden(_,#{'module':=atom(), _=>_}) -> any().
forbidden(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, forbidden, Req, State, fun forbidden_default/2).

-spec forbidden_default(_,map()) -> any().
forbidden_default(Req, State = #{mro_call := true}) ->
  decirest_auth:forbidden(Req, State);
forbidden_default(Req, State = #{module := Module}) ->
  Continue = fun({false, _, _}) -> true; (_) -> false end,
  {Res, ReqNew, StateNew} = decirest:call_mro(forbidden, Req, State, false, Continue),
  {maps:get(Module, Res, true), ReqNew, StateNew}.

-spec allowed_methods(_,#{'module':=atom(), _=>_}) -> any().
allowed_methods(Req, State = #{module := Module}) ->
  {Methods, Req1, State1} =
    decirest:do_callback(Module, allowed_methods, Req, State, fun allowed_methods_default/2),
  case cowboy_req:method(Req) of
    <<"OPTIONS">> ->
      %% We need to keep allowed_methods in state to
      %% be able to return in headers if recource implement
      %% options/2 call back.
      {Methods, Req1, State1#{allowed_methods => Methods}};
    _ ->
      {Methods, Req1, State1}
  end.

-spec allowed_methods_default(_,#{'module':=atom(), _=>_}) -> {[<<_:24,_:_*8>>,...],_,#{'module':=atom(), _=>_}}.
allowed_methods_default(Req, State = #{module := Module}) ->
  Methods0 =
    case decirest_handler_lib:is_exported(Module, validate_payload, [2,3]) of
      true ->
        [<<"PUT">>, <<"PATCH">>];
      false ->
        []
    end,
  Methods =
    case decirest_handler_lib:is_exported(Module, delete_data, 2) of
      true ->
        [<<"DELETE">> | Methods0];
      false ->
        Methods0
    end,
  {[<<"HEAD">>, <<"GET">>, <<"OPTIONS">> | Methods], Req, State}.

options(Req, State) ->
  decirest_handler_lib:options(Req, State).

-spec content_types_accepted(_,#{'module':=atom(), _=>_}) -> any().
content_types_accepted(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, content_types_accepted, Req, State, fun content_types_accepted_default/2).

-spec content_types_accepted_default(_,_) -> {[{{_,_,_},'from_fun'},...],_,_}.
content_types_accepted_default(Req, State) ->
  {[
    {{<<"application">>, <<"json">>, '*'}, from_fun},
    {{<<"application">>, <<"javascript">>, '*'}, from_fun}
  ], Req, State}.

-spec from_fun(_,#{'module':=atom(), _=>_}) -> any().
from_fun(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, from_fun, Req, State, fun from_fun_default/2).

-spec from_fun_default(map(),#{'module':=atom(), _=>_}) -> {'false',#{'resp_body':=_, _=>_},#{'module':=atom(), _=>_}} | {'stop',map(),#{'module':=atom(), _=>_}} | {'true',map(),_}.
from_fun_default(Req0 = #{method := Method}, State = #{module := Module}) ->
  % gate 2 here
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  MB = case decirest_handler_lib:is_exported(Module, ident, 0) of
         true ->
           cowboy_req:binding(Module:ident(), Req);
         false ->
           undefined
       end,
  case decirest_handler_lib:validate_payload(Body, Req, State#{method => Method, module_binding => MB}) of
    {ok, Payload} ->
      % gate3 auth here
      case decirest_handler_lib:persist_data(Payload, Req, State) of
        {ok, NewState} ->
          {true, Req, NewState};
        {error, NewState} ->
          ReqNew = cowboy_req:set_resp_body(<<"error">>, Req),
          {stop, ReqNew, NewState};
        {StatusCode, NewState} when is_number(StatusCode) ->
          ReqNew = cowboy_req:reply(StatusCode, Req),
          {stop, ReqNew, NewState};
        {StatusCode, RespBody, NewState} when is_number(StatusCode) ->
          ReqNew = cowboy_req:reply(StatusCode, #{}, RespBody, Req),
          {stop, ReqNew, NewState}
      end;
    {stop, NewReq, NewState} ->
      {stop, NewReq, NewState};
    {error, Errors} ->
      lager:critical("errors ~p", [Errors]),
      RespBody = jiffy:encode(Errors, [force_utf8]),
      ReqNew = cowboy_req:set_resp_body(RespBody, Req),
      {false, ReqNew, State}
  end.

-spec delete_resource(map(), #{module := atom(), _ => _}) -> {true | false, map(), map()}.
delete_resource(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, delete_resource, Req, State, fun delete_resource_default/2).

-spec delete_resource_default(map(), #{module := atom(), _ => _}) -> {true | false, map(), map()}.
delete_resource_default(Req, State) ->
  decirest_handler_lib:delete_data(Req, State).

-spec content_types_provided(_,#{'module':=atom(), _=>_}) -> any().
content_types_provided(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, content_types_provided, Req, State, fun content_types_provided_default/2).

-spec content_types_provided_default(_,_) -> {[{{_,_,_},'to_fun' | 'to_html' | 'to_json'},...],_,_}.
content_types_provided_default(Req, State) ->
  {[
    {{<<"text">>, <<"html">>, '*'}, to_html},
    {{<<"application">>, <<"json">>, '*'}, to_json},
    {{<<"application">>, <<"javascript">>, '*'}, to_json},
    {{<<"application">>, <<"octet-stream">>, '*'}, to_fun}
  ], Req, State}.

-spec to_fun(_,#{'module':=atom(), _=>_}) -> any().
to_fun(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, to_fun, Req, State, fun to_fun_default/2).

-spec to_fun_default(_,#{'module':=atom(), _=>_}) -> any().
to_fun_default(Req, State) ->
  to_json(Req, State).

-spec to_html(_,#{'module':=atom(), _=>_}) -> any().
to_html(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, to_html, Req, State, fun to_html_default/2).

-spec to_html_default(_,#{'module':=atom(), _=>_}) -> {_,_,_}.
to_html_default(Req, State = #{module := Module}) ->
  {Json, ReqNew, StateNew} = to_json(Req, State),
  Title = Module:name(),
  Context = [
    {title, Title},
    {single_data, Json}
  ],
  {ok, Body} = std_response_html_dtl:render(Context),
  {Body, ReqNew, StateNew}.

-spec to_json(_,#{'module':=atom(), _=>_}) -> any().
to_json(Req, State = #{module := Module}) ->
  decirest:do_callback(Module, to_json, Req, State, fun to_json_default/2).

-spec to_json_default(_,#{'module':=_, 'rstate':=map(), _=>_}) -> {binary(),_,#{'child_fun':=fun((_) -> any()), 'module':=_, 'rstate':=map(), _=>_}}.
to_json_default(#{path := Path} = Req, State = #{module := Module, rstate := RState}) ->
  #{Module := #{data := Data}} = RState,
  ChildUrls = decirest:child_urls_map(decirest:get_children(Module), Req, State),
  PrettyConfig = decirest_handler_lib:maybe_pretty(Req, State),
  {jiffy:encode(maps:merge(ChildUrls, Data#{self_url => Path}), [force_utf8] ++ PrettyConfig), Req, State}.

-spec resource_exists(_,#{'module':=atom(), _=>_}) -> any().
resource_exists(Req, State = #{module := Module}) ->
  decirest:apply_with_default(Module, resource_exists, [Req, State], fun resource_exists_default/2).

-spec resource_exists_default(_,#{'module':=_, _=>_}) -> any().
resource_exists_default(Req, State = #{mro_call := true, module := Module, rstate := RState}) ->
  case decirest_handler_lib:fetch_data(Req, State) of
    {ok, [Data]} ->
      decirest_auth:gate2(Req, State#{rstate => RState#{Module => #{data => Data}}});
    {ok, []} ->
      {false, Req, State};
    {ok, Data} when is_list(Data) ->
      ReqNew = cowboy_req:reply(409, Req),
      {stop, ReqNew, State};
    {ok, Data} ->
      decirest_auth:gate2(Req, State#{rstate => RState#{Module => #{data => Data}}});
    {error, Reason} ->
      lager:debug("got exception when fetching data ~p", [Reason]),
      {false, Req, State};
    {StatusCode, NewState} when is_number(StatusCode) ->
      ReqNew = cowboy_req:reply(StatusCode, Req),
      {stop, ReqNew, NewState};
    {StatusCode, RespBody, NewState} when is_number(StatusCode) ->
      ReqNew = cowboy_req:reply(StatusCode, #{}, RespBody, Req),
      {stop, ReqNew, NewState}
  end;
resource_exists_default(Req, State = #{module := Module}) ->
  Continue = fun({true, _, _}) -> true;(_) -> false end,
  {Res, ReqNew, StateNew} = decirest:call_mro(resource_exists, Req, State, true, Continue),
  {maps:get(Module, Res, false), ReqNew, StateNew}.
