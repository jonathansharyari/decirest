-module(decirest).
-export([
  call_mro/3,
  call_mro/4,
  call_mro/5,
  continue_mro/0,
  continue_mro/1,
  get_children/1,
  child_fun_factory/1,
  child_url/3,
  child_urls_map/3,
  is_ancestor/2,
  module_pk/1,
  do_callback/4,
  do_callback/5,
  apply_with_default/4,
  pretty_path/1,
  get_parent/1,
  get_parent_pk/1,
  t2b/1,
  get_data/2,
  get_data/3,
  get_data/4,
  change_module/2
]).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.

-spec build_routes_with_state(_,_,#{'module':=_, 'mro':=[any()], _=>_}) -> [{_,_,_}].
build_routes_with_state(Mod, Handler, State = #{mro := MRO}) when is_map(State) ->
  case sets:is_element(Mod, sets:from_list(MRO)) of
    true ->
      [];
    false ->
      lists:flatten(build_routes_path(Mod:paths(), Handler, State#{mro => [Mod | MRO], module => Mod}))
  end.

-spec build_routes_path([any()],_,atom() | #{'module':=atom(), 'mro':=[any(),...], _=>_}) -> [[{_,_,_}] | {_,_,map()}].
build_routes_path(Paths, Handler, Mod) when is_atom(Mod) ->
  build_routes_path(Paths, Handler, #{mro => [Mod] , module => Mod}, []);
build_routes_path(Paths, Handler, State) when is_map(State) ->
  build_routes_path(Paths, Handler, State, []).

-spec build_routes_path([any()],_,_,[[{_,_,_}] | {_,_,map()}]) -> [[{_,_,_}] | {_,_,map()}].
build_routes_path([Path | Paths], Handler, State = #{module := Mod}, Res0) ->
  case Mod:child_of() of
    [] ->
      build_routes_path(Paths, Handler, State, [{Path, Handler, State} | Res0]);
    Parents ->
      Res = build_routes_parent(Parents, {Path, Handler, State}, Res0),
      build_routes_path(Paths, Mod, Handler, Res)
  end;
build_routes_path([], _Handler, _State, Res) ->
  Res.

-spec build_routes_parent([any()],{_,_,#{'module':=_, _=>_}},[[{_,_,_}] | {_,_,map()}]) -> [[{_,_,_}] | {_,_,map()}].
build_routes_parent([Parent | Parents], Cfg = {_, Handler, State}, Res) ->
  build_routes_parent(Parents, Cfg, [merge_routes(build_routes_with_state(Parent, Handler, State), Cfg) | Res]);
build_routes_parent([], _Cfg, Res) ->
  Res.

-spec merge_routes([{_,_,map()}],{_,_,#{'module':=_, _=>_}}) -> [{nonempty_maybe_improper_list(),_,map()}].
merge_routes(ParentRoutes, Cfg) ->
  merge_routes(ParentRoutes, Cfg, []).

-spec merge_routes([{_,_,map()}],{_,_,#{'module':=_, _=>_}},[{nonempty_maybe_improper_list(),_,map()}]) ->
  [{nonempty_maybe_improper_list(),_,map()}].
merge_routes([ParentRoute | ParentRoutes], Cfg = {Path, Handler, #{module := Mod}}, Res0) ->
  {ParentPath, _, PState} = ParentRoute,
      Res = [{[ParentPath | Path], Handler, PState#{module => Mod}} | Res0],
      merge_routes(ParentRoutes, Cfg, Res);
merge_routes([], _Cfg, Res) ->
  Res.

get_children(Resource) ->
  persistent_term:get({?MODULE, Resource}, []).

-spec child_fun_factory([any()]) -> fun((_) -> [any()]).
child_fun_factory(Resources) ->
  [persistent_term:erase({?MODULE, Resource}) || Resource <- Resources],
  [add_resource_as_child(Resource) || Resource <- Resources],
  ok.

add_resource_as_child(Rersource) ->
  [add_child(Parent, Rersource) || Parent <- Rersource:child_of(), is_children_visible(Parent)].

add_child(Parent, Child) ->
  PrevChildren = get_children(Parent),
  persistent_term:put({?MODULE, Parent}, [Child | PrevChildren]).

-spec child_url(atom(),#{'path':=binary() | maybe_improper_list(any(),binary() | []) | byte(), _=>_},_) -> binary().
child_url(Module, #{path := Path}, _State) ->
  ChildPath =
    case erlang:function_exported(Module, paths, 0) of
      true ->
        case Module:paths() of
          [{P, _} | _] ->
            P;
          [{P, _, _} | _] ->
            P
        end;
      false ->
        Module:name()
    end,
  pretty_path([Path, "/", ChildPath]).

is_children_visible(Module) ->
  case erlang:function_exported(Module, paths, 0) of
    true ->
      case Module:paths() of
        [{_, _} | _] ->
          true;
        [{_, _, #{children := false}} | _] ->
          false;
        [{_, _, #{children := hidden}} | _] ->
          false;
        [{_, _, _} | _] ->
          true
      end;
    false ->
      true
  end.

-spec child_urls_map([atom()],_,_) -> map().
child_urls_map(Children, Req, State) ->
  child_urls_map(Children, Req, State, #{}).

-spec child_urls_map([atom()],_,_,map()) -> map().
child_urls_map([Child | Children], Req, State, Map) ->
  case do_callback(Child, forbidden, Req, State, false) of
    {false, _, _} ->
      case apply_with_default(Child, child_url, [Child, Req, State], fun child_url/3) of
        #{} = Res ->
          child_urls_map(Children, Req, State, maps:merge(Map, Res));
        Url ->
          Key = << (Child:name())/binary, "_url">>,
          child_urls_map(Children, Req, State, Map#{Key => Url})
      end;
    {true, _, _} ->
      child_urls_map(Children, Req, State, Map)
  end;
child_urls_map([], _Req, _State, Map) ->
  Map.

-spec pretty_path(binary() | maybe_improper_list(binary() | maybe_improper_list(any(),binary() | []) | byte(),binary() | [])) -> binary().
pretty_path(Path) when is_binary(Path) ->
  case binary:replace(Path, <<"//">>, <<"/">>, [global]) of
    Path ->
      Path;
    NewPath ->
      pretty_path(NewPath)
  end;
pretty_path(Path) when is_list(Path) ->
  pretty_path(iolist_to_binary(Path)).

-spec call_mro(_,_,#{'module':=_, 'mro':=maybe_improper_list(), _=>_}) -> {map(),_,#{'module':=_, 'mro_call':='false', _=>_}}.
call_mro(Callback, Req, State) ->
  call_mro(Callback, Req, State, undefined, fun(_) -> true end).

-spec call_mro(_,_,#{'module':=_, 'mro':=maybe_improper_list(), _=>_},_) -> {map(),_,#{'module':=_, 'mro_call':='false', _=>_}}.
call_mro(Callback, Req, State, Default) ->
  call_mro(Callback, Req, State, Default, fun(_) -> true end).

-spec call_mro(_,_,#{'module':=_, 'mro':=maybe_improper_list(), _=>_},_,_) -> {map(),_,#{'module':=_, 'mro_call':='false', _=>_}}.
call_mro(Callback, Req, State = #{mro := MRO, module := Module}, Default, Continue) ->
  {Res, NewReq, NewState} = call_mro(MRO, Callback, Req, State#{mro_call => true}, Default, Continue, #{}),
  {Res, NewReq, NewState#{mro_call => false, module => Module}}.

-spec call_mro(maybe_improper_list(),_,_,_,_,_,map()) -> {map(),_,_}.
call_mro([{Handler, Mod} | MRO], Callback, Req0, State0, Default, Continue, Res0) ->
  {ModRes, Req, State} = CallbackRes = do_callback(Handler, Callback, Req0, State0#{module => Mod}, Default),
  Res = Res0#{Mod => ModRes},
  case Continue(CallbackRes) of
    true ->
      call_mro(MRO, Callback, Req, State, Default, Continue, Res);
    false ->
      {Res, Req, State}
  end;
call_mro([], _Callback, Req, State, _Default, _Continue, Res) ->
  {Res, Req, State}.

continue_mro() ->
  continue_mro(true).

continue_mro(Match) ->
  fun({Match, _, _}) -> true;(_) -> false end.

-spec is_ancestor(atom(), map()) -> true | false.
is_ancestor(Module, #{mro := MRO}) ->
  lists:keymember(Module, 2, MRO).

get_parent(#{mro := MRO, module := CurrentModule}) ->
  get_parent(lists:reverse(MRO), CurrentModule).

get_parent([{_, CurrentModule}, {_, Parent} | _Tail], CurrentModule) ->
  Parent;

get_parent([{_, _}, {Handler, Parent} | Tail], CurrentModule) ->
  get_parent([{Handler, Parent} | Tail], CurrentModule).

get_parent_pk(State) ->
  Parent = get_parent(State),
  {Parent, module_pk(Parent)}.

-spec module_pk(atom()) -> any().
module_pk(Module) ->
  case erlang:function_exported(Module, data_pk, 0) of
    true ->
      Module:data_pk();
    false ->
      id
  end.

-spec do_callback(atom(),atom(),_,_,_) -> any().
do_callback(Callback, Req, #{module := Module} = State, Default) ->
  do_callback(Module, Callback, Req, State, Default).

do_callback(Module, Callback, Req, State, Default) ->
  case erlang:function_exported(Module, Callback, 2) of
    true ->
      Module:Callback(Req, State);
    false ->
      case is_function(Default) of
        true ->
          % TODO: we don't send Mod, the more specified MRO in state should be enough
          Default(Req, State);
        false ->
          {Default, Req, State}
      end
  end.

-spec apply_with_default(atom(),atom(),[any()],_) -> any().
apply_with_default(M, F, A, Default) ->
  case erlang:function_exported(M, F, length(A)) of
    true ->
      case erlang:apply(M, F, A) of
        %% UpdatedA should be same length/type as A
        {run_default, UpdatedA} ->
          case is_function(Default) of
            true ->
              erlang:apply(Default, UpdatedA);
            false ->
              exit(run_default_not_a_function)
          end;
        Res ->
          Res
      end;
    false ->
      case is_function(Default) of
        true ->
          erlang:apply(Default, A);
        false ->
          Default
      end
  end.

-spec get_data(atom(), map()) -> any().
get_data(Module, #{rstate := RState}) ->
  get_data(Module, RState);
get_data(Module, State) ->
  case State of
    #{Module := #{data := Data}} ->
      Data;
    _ ->
      undefined
  end.

-spec get_data(any(), atom(), map()) -> any().
get_data(Key, Module, State) when is_atom(Module) ->
  get_data(Key, Module, State, undefined).

-spec get_data(any(), atom(), map(), any()) -> any().
get_data(Key, Module, State, Default) ->
  case get_data(Module, State) of
    #{Key := Val} ->
      Val;
    #{} = Data ->
      case proplists:get_value(inu:t2b(Key), [{inu:t2b(K), K} || K <- maps:keys(Data)]) of
        undefined ->
          Default;
        RawKey ->
          maps:get(RawKey, Data)
      end;
    _ ->
      Default
  end.

%%------------------------------------------------------------------------------
%% @doc makes it possible to reroute to a different module
%%      Can be used to implement api versions
%%      Should be used in init/2 in handler implementations
%%
%%      init(Req, State) ->
%%          {run_default, [Req, decirest:change_module(different_modules, State)]}.
%%
%% @end
%%------------------------------------------------------------------------------
-spec change_module(Module, State) -> State when
  Module :: atom(),
  State :: map(). %% Decirest state
change_module(Module, #{mro := MRO} = State) ->
  [{Handler, _OldModule} | Tail] = lists:reverse(MRO),
  State#{module => Module, main_module => Module, mro => lists:reverse([{Handler, Module}| Tail])}.

-spec t2b(atom() | binary() | maybe_improper_list(binary() | maybe_improper_list(any(),binary() | []) | byte(),binary() | []) | integer()) -> binary().
t2b(V) when is_integer(V) -> integer_to_binary(V);
t2b(V) when is_list(V) -> list_to_binary(V);
t2b(V) when is_atom(V) -> atom_to_binary(V, utf8);
t2b(V) when is_binary(V) -> V.

-ifdef(TEST).

child_url_test() ->
  Path = <<"/api/v1/company/1/">>,
  Req = #{
    scheme => <<"http">>,
    host => <<"localhost">>,
    port => 8080,
    path => Path,
    qs => <<"dummy=2785">>
  },
  ChildPath = "user",
  ?assert(lists:member(Path, cowboy_req:uri(Req, #{host => undefined}))),
  ?assertEqual(pretty_path([Path, "/", ChildPath]), <<"/api/v1/company/1/user">>).

get_parent_test() ->
  State = #{mro =>
  [{decirest_single_handler, res_1},
    {decirest_single_handler, res_2},
    {decirest_single_handler, res_3},
    {decirest_single_handler, res_4},
    {decirest_single_handler, res5}],
    module => res_3},
  ?assertEqual(res_2, get_parent(State)).

-endif.
