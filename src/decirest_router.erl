-module(decirest_router).
-export([
  build_routes/1, build_routes/2,
  get_paths/2
]).

get_paths(Module, Options) ->
  case erlang:function_exported(Module, paths, 0) of
    true ->
      prep_paths(Module:paths(), Options#{pp_mod => Module});
    false ->
      prep_paths(make_paths(Module, Options), Options#{pp_mod => Module})
  end.

make_paths(Module, #{single_handler := SH, collection_handler := CH}) ->
  Name = Module:name(),
  Ident = atom_to_list(Module:ident()),
  [{["/", Name], CH, #{children => false}}, {["/", Name, "/:", Ident], SH, #{}}];
make_paths(Module, Options) ->
  SH = maps:get(single_handler, Options, decirest_single_handler),
  CH = maps:get(collection_handler, Options, decirest_collection_handler),
  make_paths(Module, Options#{single_handler => SH, collection_handler => CH}).

prep_paths(Paths, Options) ->
  prep_paths(Paths, Options, []).

prep_paths([PathDef | Paths], Options = #{pp_mod := Module}, Res) ->
  {Path, Handler, PState} = case PathDef of
                          {P, H, S} ->
                            {P, H, S#{module => Module}};
                          {P, H} ->
                            {P, H, #{module => Module}}
                        end,
  State = maps:get(state, Options, #{}),
  prep_paths(Paths, Options, [{Path, Handler, maps:merge(State, PState)} | Res]);
prep_paths([], _Options, Res) ->
  Res.


build_routes(Modules) ->
  build_routes(Modules, #{}).

build_routes(Modules, Options) when is_list(Modules) ->
  State = maps:get(state, Options, #{}),
  ChildFun = decirest:child_fun_factory(Modules),
  build_routes(Modules, Options#{state => State#{child_fun => ChildFun}}, []);
build_routes(Module, Options) ->
  %Module:module_info(),
  State = maps:get(state, Options, #{}),
  ChildFun = decirest:child_fun_factory([Module]),
  build_routes([Module], Options#{state => State#{child_fun => ChildFun}}, []).

build_routes([Module | Modules], Options, Res) ->
  build_routes(Modules, Options, [build_module_routes(Module, Options) | Res]);
build_routes([], _Options, Res) ->
  [{'_', [], lists:flatten(Res)}].

build_module_routes(Module, Options = #{state := State = #{mro := MRO}}) ->
  case sets:is_element(Module, sets:from_list(MRO)) of
    true ->
      [];
    false ->
      case erlang:function_exported(Module, get_routes, 1) of
        true ->
          Module:get_routes(Options);
        false ->
          br(Module, Options#{state => State#{mro => [Module | MRO]}})
      end
  end;
build_module_routes(Module, Options) ->
  State = maps:get(state, Options, #{}),
  build_module_routes(Module, Options#{state => State#{mro => []}}).


br(Module, Options) ->
Paths = get_paths(Module, Options),
  case Module:child_of() of
    [] ->
      Paths;
    Parents ->
      merge_with_parents(Parents, Paths, Options, [])
  end.

merge_with_parents([Parent | Parents], Paths, Options, Res) ->
  ParentRoutes = lists:flatten(build_module_routes(Parent, Options)),
  merge_with_parents(Parents, Paths, Options, merge_with_parent(ParentRoutes, Paths, Res));
merge_with_parents([], _Paths, _Options, Res) ->
  Res.

merge_with_parent([{_Path, _Handler, #{children := false}} | ParentPaths], Paths, Res) ->
  merge_with_parent(ParentPaths, Paths, Res);
merge_with_parent([{Path, _Handler, #{} = PState} | ParentPaths], Paths, Res) ->
  NewPaths = [{[Path | P], H, maps:merge(PState, maps:without([mro], S))} || {P, H, S} <- Paths],
  merge_with_parent(ParentPaths, Paths, [NewPaths | Res]);
merge_with_parent([{'_', _, ParentPaths} | Routes], Paths, Res) ->
  merge_with_parent(Routes, Paths, merge_with_parent(ParentPaths, Paths, Res));
merge_with_parent([], _Paths, Res) ->
  Res.


