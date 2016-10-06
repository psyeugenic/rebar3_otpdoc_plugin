-module(rebar3_otpdoc_plugin_prv).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, otpdoc).
-define(DEPS, [app_discovery]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 otpdoc"},   % How to use the plugin
            {opts, []},                   % list of options understood by the plugin
            {short_desc, "A rebar3 plugin for building OTP documentation"},
            {desc, "A rebar3 plugin for building OTP documentation"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    [make_otpdoc(AppInfo) || AppInfo <- rebar_state:project_apps(State)],
    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%%%-----------------------------------------------------------------
make_otpdoc(AppInfo) ->
    Opts = rebar_app_info:opts(AppInfo),
    OtpOpts = proplists:unfold(rebar_opts:get(Opts, otpdoc_opts, [])),
    %/ldisk/egil/git/otp/lib/erl_docgen/priv/bin/xml_from_edoc.escript
    OutDir = rebar_app_info:out_dir(AppInfo),
    DocSrc = filename:join([rebar_app_info:dir(AppInfo),"doc","src"]),
    XmlFiles = filelib:wildcard(filename:join(DocSrc,"*.xml")),
    Details = rebar_app_info:app_details(AppInfo),
    io:format("~p~n", [rebar_app_info:name(AppInfo)]),
    io:format("Details: ~p~n", [Details]),
    io:format("Opts: ~p~n", [OtpOpts]),
    io:format("XmlFiles: ~p~n", [XmlFiles]),
    {Details,XmlFiles}.
