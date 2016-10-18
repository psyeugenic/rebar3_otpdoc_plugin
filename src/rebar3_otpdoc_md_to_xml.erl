%%
%% Copyright (C) 2016 Björn-Egil Dahlberg
%%
%%-------------------------------------------------------------------
%% File    : rebar3_md_to_xml.erl
%% Author  : Rickard Green (emd2exml)
%% Modified: Björn-Egil Dahlberg
%%
%% Description : Erlangish MarkDown To Erlangish XML
%%
%%         Note that this script has *one and only one*
%%         specific purpose. That purpose is to generate XML
%%         that fits into the Erlang/OTP documentation, so that
%%         the Erlang/OTP "readme" files also can be part of
%%         the Erlang/OTP HTML and Erlang/OTP PDF
%%         documentation. Nothing more, nothing less. It is
%%         *not* intended as some kind of a generic Markdown to
%%         XML tool, and never will be.
%%
%% Created : 25 Feb 2010 by Rickard Green
%%-------------------------------------------------------------------

-module(rebar3_otpdoc_md_to_xml).

-define(MAX_HEADING, 6).

-define(DELAYED_COPYRIGHT_IX, 0).
-define(DELAYED_TOC_IX, 1).
-define(DELAYED_START_IX, 2).

-define(DBG(Format,Args), rebar_api:debug(Format,Args)).
-define(ABORT(Format,Args), rebar_api:abort(Format,Args)).

-export([translate/2]).

-record(state,{h = 0,
	       p = false,
	       c = no,
	       note = false,
	       warning = false,
	       emphasis = no,
	       code = false,
	       code_blank = [],
	       bq_lvl = 0,
	       mlist = [],
	       list_p = false,
	       list_type_stack = [],
	       list_p_stack = [],
	       list_lvl = 0,
	       line_no = -1,
	       line = "",
	       type = blank,
	       bq_type = 0,
	       prev_line = "",
	       prev_type = blank,
	       next_line = "",
	       next_type = blank,
	       bq_next_type = 0,
	       delayed_array,
	       delayed_array_ix = ?DELAYED_START_IX,
	       delayed_tree,
	       out = [],
	       copyright = false,
	       copyright_data = [],
	       have_h1 = false,
	       toc = [],
	       ifile,
	       ofile}).

translate(I, O) ->
    IFD = file_ropen(I),
    S0 = get_line(get_line(#state{ifile = IFD,
				  ofile = {O, undefined},
				  delayed_array = array:new(),
				  delayed_tree = gb_trees:empty()})),
    S1 = complete_output(parse(S0)),
    file_close(IFD),
    OFD = file_wopen(O),
    write_output(OFD, S1#state.out),
    file_close(OFD),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Parser
%%

%%
%% Eof
%%

parse(#state{h = H, line = eof} = S) ->
    sections(0, H, end_all(S));

%%
%% Note
%%

parse(#state{line = "> *NOTE*: " ++ Line,
	     note = false,
	     type = {bquote, 0, 1}} = S0) ->
    S1 = put_line(end_all(S0#state{note = true, bq_lvl = 1}), "<note>"),
    parse(S1#state{line = Line, type = type(Line), bq_type = 1});

parse(#state{bq_lvl = 1, note = true, bq_type = 0} = S) ->
    parse(put_line(end_all(S#state{bq_lvl = 0, note = false}), "</note>"));

%%
%% Warning
%%

parse(#state{line = "> *WARNING*: " ++ Line,
	     warning = false,
	     type = {bquote, 0, 1}} = S0) ->
    S1 = put_line(end_all(S0#state{warning = true, bq_lvl = 1}), "<warning>"),
    parse(S1#state{line = Line, type = type(Line), bq_type = 1});

parse(#state{bq_lvl = 1, warning = true, bq_type = 0} = S) ->
    parse(put_line(end_all(S#state{bq_lvl = 0, warning = false}), "</warning>"));

%%
%% Block quote
%%

parse(#state{note = false,
	     warning = false,
	     line = BQLine,
	     type = {bquote, TxtLvl, BQLvl}} = S0) ->
    Line = rm_bquote(TxtLvl, BQLvl, BQLine),
    S1 = chg_bq_lvl(BQLvl, S0),
    parse(S1#state{line = Line, type = type(Line), bq_type = BQLvl});

% This clause is also used by warning and note
parse(#state{bq_lvl = BQLvl,
	     next_line = BQLine,
	     next_type = {bquote, TxtLvl, BQLvl}} = S) ->
    Line = rm_bquote(TxtLvl, BQLvl, BQLine),
    parse(S#state{next_line = Line,
		  next_type = type(Line),
		  bq_next_type = BQLvl});

parse(#state{note = false,
	     warning = false,
	     bq_lvl = Lvl, bq_type = 0} = S) when Lvl /= 0->
    parse(chg_bq_lvl(0, S));

%%
%% Multiple blank lines
%%

% Keep multiple blank lines in code otherwise get rid of them...
parse(#state{code = false, type = blank, next_type = blank} = S) ->
    parse(get_line(S));

%%
%% Heading
%%

parse(#state{type = {text, 0}, next_type = {marker, h1}} = S) ->
    parse(get_line(get_line(setext_heading(1, end_all(S)))));
parse(#state{type = {text, 0}, next_type = {marker, h2}} = S) ->
    parse(get_line(get_line(setext_heading(2, end_all(S)))));
parse(#state{line = "#" ++ _} = S) ->
    parse(get_line(atx_heading(end_all(S))));

%%
%% List
%%

parse(#state{code = false,
	     list_lvl = Lvl,
	     type = blank,
	     next_type = {text, 0}} = S) when Lvl /= 0 ->
    parse(get_line(chg_list_lvl(S, 0)));

parse(#state{code = false,
	     list_lvl = Lvl,
	     type = blank,
	     next_type = {text, TxtLvl}} = S) when Lvl /= 0,
						    TxtLvl >= Lvl ->
    parse(get_line(put_line(list_use_p(S, yes), "")));

parse(#state{code = false,
	     list_lvl = Lvl,
	     type = blank,
	     next_type = {uolist, ListLvl}} = S) when Lvl /= 0,
                                                      ListLvl >= Lvl-1 ->
    parse(get_line(put_line(list_use_p(S, yes), "")));

parse(#state{code = false,
	     list_lvl = Lvl,
	     type = blank,
	     next_type = {olist, ListLvl}} = S) when Lvl /= 0,
                                                     ListLvl >= Lvl-1 ->
    parse(get_line(put_line(list_use_p(S, yes), "")));

parse(#state{code = false,
	     type = {ListType, ListLvl},
	     line = Line} = S0) when ListType == uolist; ListType == olist ->
    S1 = list_item(end_p(S0), ListType, ListLvl),
    S2 = list_chk_nxt_line(put_text(put_list_p(S1, start),
				    list_strip(ListType, Line))),
    parse(get_line(S2));

parse(#state{code = false,
	     list_lvl = Lvl,
	     list_p = true,
	     type = {text, _},
	     line = Line} = S0) when Lvl /= 0 ->
    S1 = list_chk_nxt_line(put_text(S0, list_strip(Line))),
    parse(get_line(S1));

parse(#state{code = false,
	     list_lvl = Lvl,
	     list_p = false,
	     type = {text, NewLvl},
	     line = Line} = S0) when Lvl /= 0, NewLvl < Lvl ->
    S1 = chg_list_lvl(S0, NewLvl),
    S2 = list_chk_nxt_line(put_text(put_list_p(S1, start), list_strip(Line))),
    parse(get_line(S2));

parse(#state{code = false,
	     list_lvl = Lvl,
	     list_p = false,
	     type = {text, Lvl},
	     line = Line} = S0) when Lvl /= 0 ->
    S1 = list_chk_nxt_line(put_text(put_list_p(S0, start), list_strip(Line))),
    parse(get_line(S1));

%%
%% Code
%%

parse(#state{code = false,
	     list_lvl = Lvl,
	     p = false,
	     prev_type = blank,
	     type = {text, TxtLvl},
	     line = Line} = S) when TxtLvl > Lvl ->
    Data = code(strip_lvls(Lvl+1, Line)),
    parse(get_line(put_chars(S#state{code = true},
			    ["<code type=\"none\">", nl(), Data])));
parse(#state{code = true, type = blank, line = CB, code_blank = CBs} = S)  ->
    parse(get_line(S#state{code_blank = [CB | CBs]}));
parse(#state{code = true,
	     code_blank = CB,
	     list_lvl = Lvl,
	     type = {Type, TxtLvl},
	     line = Line} = S) when TxtLvl > Lvl,
				    (Type == text orelse
				     Type == uolist orelse
				     Type == olist)  ->
    Data = code(strip_lvls(Lvl+1, Line)),
    parse(get_line(put_chars(S#state{code_blank = []},
			    [strip_code_blank(Lvl+1, CB), Data])));
parse(#state{code = true,
	     prev_type = blank,
	     type = {text, 0}} = S)  ->
    parse(chg_list_lvl(end_code(S), 0));
parse(#state{code = true} = S)  ->
    parse(end_code(S));

%%
%% Paragraph
%%

parse(#state{p = false,
	     prev_type = blank,
	     type = {text, 0},
	     next_type = blank,
	     line = Line} = S) ->
    parse(get_line(put_line(put_text(put_line(S, "<p>"), Line), "</p>")));
parse(#state{p = false,
	     prev_type = blank,
	     type = {text, 0},
	     line = Line} = S) ->
    parse(get_line(put_text(put_line(S#state{p = true}, "<p>"), Line)));
parse(#state{p = true,
	     type = {text, 0},
	     next_type = blank,
	     line = Line} = S) ->
    parse(get_line(put_line(put_text(S#state{p = false}, Line), "</p>")));

%%
%% Resolve link
%%

parse(#state{type = resolve_link} = S) ->
    parse(get_line(resolve_link(S)));

%%
%% Plain text
%%

parse(#state{line = Line} = S) ->
    parse(get_line(put_text(S, Line))).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Auxilary functions
%%%

%%
%% Text
%%

end_p(#state{p = false} = S) ->
    S;
end_p(#state{p = true} = S) ->
    put_line(S#state{p = false}, "</p>").

text(Line) ->
    text(Line, []).

text("%ERTS-VSN%" ++ Cs, Acc) ->
    Vsn = erlang:system_info(version),
    text(Cs, [Vsn|Acc]);
text("%OTP-VSN%" ++ Cs, Acc) ->
    Rel = erlang:system_info(otp_release),
    text(Cs, [Rel|Acc]);
text("%OTP-REL%" ++ Cs, Acc) ->
    Rel = erlang:system_info(otp_release),
    text(Cs, [Rel|Acc]);

text([$\\,C|Cs], Acc) ->
    text(Cs, [C|Acc]);
text([$<|Cs], Acc) ->
    text(Cs, ["&lt;"|Acc]);
text([$>|Cs], Acc) ->
    text(Cs, ["&gt;"|Acc]);
text([$&|Cs], Acc) ->
    text(Cs, ["&amp;"|Acc]);
text([$'|Cs], Acc) ->
    text(Cs, ["&apos;"|Acc]);
text([C|Cs], Acc) ->
    text(Cs, [C|Acc]);
text([], Acc) ->
    lists:reverse(Acc).

put_text(#state{c = CTag, emphasis = EmTag} = S, Line) ->
    put_text(S, Line, CTag, EmTag, []).

put_text(S, "%ERTS-VSN%"++Cs, CTag, EmTag, Acc) ->
    Vsn = erlang:system_info(version),
    put_text(S, Cs, CTag, EmTag, [Vsn|Acc]);
put_text(S, "%OTP-VSN%"++Cs, CTag, EmTag, Acc) ->
    Rel = erlang:system_info(otp_release),
    put_text(S, Cs, CTag, EmTag, [Rel|Acc]);
put_text(S, "%OTP-REL%"++Cs, CTag, EmTag, Acc) ->
    Rel = erlang:system_info(otp_release),
    put_text(S, Cs, CTag, EmTag, [Rel|Acc]);

put_text(S, [$\\,C|Cs], no, EmTag, Acc) ->
    put_text(S, Cs, no, EmTag, [C|Acc]);
put_text(S, [C,C|Cs], no, b, Acc) when C == $*; C == $_ ->
    put_text(S, Cs, no, no, ["</strong>"|Acc]);
put_text(S, [C,C|Cs], no, no, Acc) when C == $*; C == $_ ->
    put_text(S, Cs, no, b, ["<strong>"|Acc]);
put_text(S, [C|Cs], no, em, Acc) when C == $*; C == $_ ->
    put_text(S, Cs, no, no, ["</em>"|Acc]);
put_text(S, [C|Cs], no, no, Acc) when C == $*; C == $_ ->
    put_text(S, Cs, no, em, ["<em>"|Acc]);
put_text(S, [$`,$`|Cs], double, EmTag, Acc) ->
    put_text(S, Cs, no, EmTag, ["</c>"|Acc]);
put_text(S, [$`,$`|Cs], no, EmTag, Acc) ->
    put_text(S, Cs, double, EmTag, ["<c>"|Acc]);
put_text(S, [$`|Cs], single, EmTag, Acc) ->
    put_text(S, Cs, no, EmTag, ["</c>"|Acc]);
put_text(S, [$`|Cs], no, EmTag, Acc) ->
    put_text(S, Cs, single, EmTag, ["<c>"|Acc]);
put_text(S, [$<|Cs], CTag, EmTag, Acc) when CTag /= no ->
    put_text(S, Cs, CTag, EmTag, ["&lt;"|Acc]);
put_text(S, [$>|Cs], CTag, EmTag, Acc) when CTag /= no ->
    put_text(S, Cs, CTag, EmTag, ["&gt;"|Acc]);
put_text(S, [$&|Cs], CTag, EmTag, Acc) when CTag /= no ->
    put_text(S, Cs, CTag, EmTag, ["&amp;"|Acc]);
put_text(S, [$&, $  |Cs], CTag, EmTag, Acc) -> %Workaround for INSTALL-WIN32.md
     put_text(S, Cs, CTag, EmTag, ["&amp; "|Acc]);
put_text(S, [$'|Cs], CTag, EmTag, Acc)when CTag /= no  ->
    put_text(S, Cs, CTag, EmTag, ["&apos;"|Acc]);
put_text(S, [$<|Cs], no, EmTag, Acc) ->
    case auto_link(Cs) of
	no -> put_text(S, Cs, no, EmTag, [$<|Acc]);
	{URL, NewCs} -> put_text(S, NewCs, no, EmTag, [URL|Acc])
    end;
put_text(S0, "![" ++ Cs, no, EmTag, Acc) ->
    put_text_link_or_image(S0, image, "![", Cs, EmTag, Acc);
put_text(S0, [$[|Cs], no, EmTag, Acc) ->
    put_text_link_or_image(S0, link, $[, Cs, EmTag, Acc);
put_text(S, "  \n", CTag, EmTag, Acc) ->
    put_text(S, [], CTag, EmTag, ["<br/>\n"|Acc]);
put_text(S, "  \r", CTag, EmTag, Acc) ->
    put_text(S, [], CTag, EmTag, ["<br/>\r"|Acc]);
put_text(S, "  \r\n", CTag, EmTag, Acc) ->
    put_text(S, [], CTag, EmTag, ["<br/>\r\n"|Acc]);
put_text(S, [C|Cs], CTag, EmTag, Acc) ->
    put_text(S, Cs, CTag, EmTag, [C|Acc]);
put_text(S0, [], CTag, EmTag, Acc) ->
    S1 = put_chars(S0, [lists:reverse(Acc)]),
    S1#state{c = CTag, emphasis = EmTag}.

put_text_link_or_image(S0, Type, Head, Tail0, EmTag, Acc) ->
    case link_or_image(Tail0, Type) of
	no -> put_text(S0, Tail0, no, EmTag, [Head|Acc]);
	{LnkOrImg, Tail1} -> put_text(S0, Tail1, no, EmTag, [LnkOrImg|Acc]);
	{delayed, Type, Key, Text, Tail1} ->
	    chk_key(Type, Key, S0),
	    S1 = put_chars(S0, [lists:reverse(Acc)]),
	    S2 = put_delayed(S1, Key, {Type, Text, S1#state.line_no}),
	    put_text(S2, Tail1, no, EmTag, [])
    end.

%%
%% Links
%%

chk_key(Type, [$?|_] = Key, #state{ifile = {File, _}, line_no = Line}) ->
    Class = case Type of
                image -> "Image";
                _ -> "Link"
            end,
    ?ABORT("~s:~w - ~s definition name `~ts' begin with a `?' character",
	  [File,Line,Class, Key]);
chk_key(_, _, _) ->
    ok.

auto_link(Str) ->
    case url(Str) of
	no -> no;
	Res -> Res
    end.

url(Str) ->
    url(Str, false, []).

url([$\\,C|Cs], Bool, Acc) ->
    url(Cs, Bool, [C|Acc]);
url([$>|_Cs], false, _Acc) ->
    no;
url([$>|Cs], true, Acc) ->
    Url = text(lists:reverse(Acc)),
    {["<url href=\"", Url, "\">", Url, "</url>"], Cs};
url("://" ++ _Cs, true, _Acc) ->
    no;
url("://" ++ Cs, false, Acc) ->
    url(Cs, true, [$/,$/,$:|Acc]);
url([C|Cs], Bool, Acc) ->
    url(Cs, Bool, [C|Acc]).

link_or_image(Str, Type) ->
    case link_or_image_text(Str, "") of
        no -> no;
        {Text, Cont1} ->
            case link_or_image_data(Cont1, none, Type, "", "") of
                no -> no;
                {url, Url, _Title, Cont2} ->
                    {["<url href=\"", text(Url), "\">", text(Text), "</url>"],
                     Cont2};
                {seealso, SeeAlso, _Title, Cont2} ->
                    {["<seealso marker=\"", text(SeeAlso), "\">",
                      text(Text), "</seealso>"],
                     Cont2};
                {image, Image, Title, Cont2} ->
                    {["<image file=\"", text(Image), "\"><icaption>",
                      text(Title), "</icaption></image>"],
                     Cont2};
                {delayed, text, Cont2} ->
                    {delayed, Type, Text, Text, Cont2};
                {delayed, Key, Cont2} ->
                    {delayed, Type, Key, Text, Cont2}
            end
    end.

link_or_image_text([$\\,C|Cs], Acc) ->
    link_or_image_text(Cs, [C|Acc]);
link_or_image_text([$]|_Cs], "") ->
    no;
link_or_image_text([$]|Cs], Acc) ->
    {lists:reverse(Acc), Cs};
link_or_image_text([C|Cs], Acc) ->
    link_or_image_text(Cs, [C|Acc]);
link_or_image_text([], _Acc) ->
    no.

link_or_image_data([C|Cs], none, link, "", "") when C == $ ; C == $\t ->
    link_or_image_data(Cs, none, link, "", "");
link_or_image_data([C|Cs], none, image, "", "") when C == $ ; C == $\t ->
    link_or_image_data(Cs, none, image, "", "");

link_or_image_data([$\\,C|Cs], How, Type, Eltit, Lru) when How /= none ->
    link_or_image_data(Cs, How, Type, Eltit, [C|Lru]);

link_or_image_data([$(|Cs], none, link, "", "") ->
    link_or_image_data(Cs, {inline, read}, seealso, "", "");
link_or_image_data([$(|Cs], none, image, "", "") ->
    link_or_image_data(Cs, {inline, read}, image, "", "");
link_or_image_data([$)|_Cs], {inline, _}, _Type, "", "") ->
    no;
link_or_image_data([$)|Cs], {inline, _}, Type, Eltit, Lru) ->
    {Type, lists:reverse(ws_strip(Lru)), lists:reverse(ws_strip(Eltit)), Cs};
link_or_image_data("://" ++Cs, {inline, read} = IR, seealso, Eltit, Lru) ->
    link_or_image_data(Cs, IR, url, Eltit, [$/,$/,$:|Lru]);
link_or_image_data([$"|Cs], {inline, read}, Type, "", Lru) ->
    link_or_image_data(Cs, {inline, read_title}, Type, "", Lru);
link_or_image_data([$"|Cs], {inline, read_title}, Type, Eltit, Lru) ->
    link_or_image_data(Cs, {inline, drop}, Type, Eltit, Lru);
link_or_image_data([C|Cs], {inline, read} = IR, Type, "", Lru) ->
    link_or_image_data(Cs, IR, Type, "", [C|Lru]);
link_or_image_data([C|Cs], {inline, read_title} = IRT, Type, Eltit, Lru) ->
    link_or_image_data(Cs, IRT, Type, [C|Eltit], Lru);
link_or_image_data([_|Cs], {inline, drop}, Type, Eltit, Lru) ->
    link_or_image_data(Cs, {inline, drop}, Type, Eltit, Lru);

link_or_image_data("[]"++Cs, none, _Type, "", "") ->
    {delayed, text, Cs};
link_or_image_data([$[|Cs], none, Type, "", "") ->
    link_or_image_data(Cs, reference, Type, "", "");
link_or_image_data(_, none, _Type, "", "") ->
    no;
link_or_image_data([$]|_Cs], reference, _Type, "", "") ->
    no;
link_or_image_data([$]|Cs], reference, _Type, "", Fer) ->
    {delayed, lists:reverse(ws_strip(Fer)), Cs};
link_or_image_data([C|Cs], reference, Type, "", Fer) ->
    link_or_image_data(Cs, reference, Type, "", [C|Fer]).

mk_image(Title, Url) ->
    ["<image file=\"", text(Url), "\"><icaption>",
     text(Title), "</icaption></image>"].

mk_link(Text, Url) ->
    case chk_proto(Url) of
	true -> ["<url href=\"", text(Url), "\">", text(Text), "</url>"];
	false -> ["<seealso marker=\"", text(Url), "\">", text(Text), "</seealso>"]
    end.

chk_proto("://" ++ _) ->
    true;
chk_proto([]) ->
    false;
chk_proto([_|Cs]) ->
    chk_proto(Cs).

%%
%% Code
%%

code(Line) ->
    code(Line, []).

code("%ERTS-VSN%" ++ Cs, Acc) ->
    Vsn = erlang:system_info(version),
    code(Cs, [Vsn|Acc]);
code("%OTP-VSN%" ++ Cs, Acc) ->
    %% not quite right
    Rel = erlang:system_info(otp_release),
    code(Cs, [Rel|Acc]);
code("%OTP-REL%" ++ Cs, Acc) ->
    Rel = erlang:system_info(otp_release),
    code(Cs, [Rel|Acc]);

code([$<|Cs], Acc) ->
    code(Cs, ["&lt;"|Acc]);
code([$>|Cs], Acc) ->
    code(Cs, ["&gt;"|Acc]);
code([$&|Cs], Acc) ->
    code(Cs, ["&amp;"|Acc]);
code([$'|Cs], Acc) ->
    code(Cs, ["&apos;"|Acc]);
code([C|Cs], Acc) ->
    code(Cs, [C|Acc]);
code([], Acc) ->
    lists:reverse(Acc).

end_code(#state{code = true} = S) ->
    put_line(S#state{code = false, code_blank = []}, "</code>");
end_code(S) ->
    S.

strip_code_blank(_Lvls, []) ->
    [];
strip_code_blank(Lvls, CBs) ->
    strip_code_blank(Lvls, CBs, []).

strip_code_blank(_Lvls, [], Acc) ->
    Acc;
strip_code_blank(Lvls, [CB|CBs], Acc) ->
    strip_code_blank(Lvls, CBs, [strip_lvls(Lvls, CB)|Acc]).

strip_lvls(0, Str) ->
    Str;
strip_lvls(N, "    " ++ Str) ->
    strip_lvls(N-1, Str);
strip_lvls(N, [$\t | Str]) ->
    strip_lvls(N-1, Str);
strip_lvls(_N, Str) ->
    Str.

%%
%% Titles and sections
%%

put_title(S, 1, Title) ->
    header(chk_h1(1, S#state{h = 1, mlist = [top]}), Title);
put_title(#state{mlist = MList0,
		 toc = TOC} = S0, H, Title) ->
    TitleStr = text(Title),
    MList1 = [mk_lvl_marker(Title) | MList0],
    Marker = mk_marker(MList1),
    S1 = chk_h1(H,
                S0#state{toc = [TOC,
				lists:duplicate(H,"  "),
				"  ",
				"<seealso marker=\"#",Marker,"\">",
				TitleStr,"</seealso>",nl()],
			 h = H,
			 mlist = MList1}),
    S2 = put_chars(S1, ["<marker id=\"", Marker, "\"/>",nl()]),
    {STag, ETag} = case H > ?MAX_HEADING of
		       true -> {"<p><strong>", "</strong></p>"};
		       false -> {"<title>", "</title>"}
		   end,
    put_chars(S2, [STag, TitleStr, ETag, nl()]).

setext_heading(H, #state{line = Line, h = OldH} = S0) ->
    S1 = sections(H, OldH, S0),
    put_title(S1, H, ws_strip(Line)).

atx_heading(#state{line = Line, h = OldH} = S0) ->
    {H, Title} = get_atx_title(Line),
    S1 = sections(H, OldH, S0),
    put_title(S1, H, ws_strip(Title)).


get_atx_title(Line) ->
    get_atx_title(Line, 0).

get_atx_title("#" ++ Rest, H) ->
    get_atx_title(Rest, H+1);
get_atx_title(Rest, H) ->
    {H, atx_strip(Rest)}.

atx_strip(S) ->
    strip(S, [$ ,$\t,$\n,$\r,$#]).

chk_h1(1, #state{have_h1 = true, ifile = {File, _}, line_no = Line}) ->
    ?ABORT("~s:~w - Multiple H1 headings", [File,Line]);
chk_h1(1, #state{have_h1 = false} = S) ->
    S#state{have_h1 = true};
chk_h1(_H, S) ->
    S.

sections(0, 0, S) ->
    S;
sections(H, H, #state{mlist = [_|ML], toc = TOC} = S0) ->
    S1 = S0#state{mlist = ML,
		  toc = [TOC,
			 lists:duplicate(H,"  "),
			 "</item><item>",nl()]},
    S2 = end_section(H, S1),
    begin_section(H, S2);
sections(H, OldH, S) ->
    sections_change(H, OldH, S).

sections_change(H, H, S) ->
    S;
sections_change(H, OldH, #state{ifile = {File, _},
				line_no = Line}) when H > OldH+1 ->
    ?ABORT("~s:~w - Level ~p heading without preceding level ~w heading", [File,Line,H,H-1]);
sections_change(H, OldH, #state{toc = TOC} = S0) when H == OldH+1 ->
    S1 = case H > 1 of
	     false -> S0;
	     true-> S0#state{toc = [TOC, lists:duplicate(H-1,"  "),
				    "<list type=\"ordered\"><item>",nl()]}
	 end,
    S2 = begin_section(H, S1),
    sections_change(H, OldH+1, S2);
sections_change(H, OldH, #state{mlist = [_|ML], toc = TOC} = S0) ->
    S1 = case OldH > 1 of
	     false -> S0;
	     true-> S0#state{toc = [TOC, lists:duplicate(OldH-1,"  "),
				    "</item></list>",nl()]}
	 end,
    S2 = end_section(OldH, S1),
    sections(H, OldH-1, S2#state{mlist = ML}).

begin_section(1, S) ->
    put_line(S, "<chapter>");
begin_section(H, S) when H > ?MAX_HEADING ->
    S;
begin_section(H, S0)  when H > 1 ->
    put_line(S0, "<section>");
begin_section(_H, S)  ->
    S.

end_section(1, S) ->
    put_chars(S, ["</chapter>",nl(),nl()]);
end_section(H, S) when H < 1; ?MAX_HEADING < H ->
    S;
end_section(_H, S) ->
    put_chars(S, ["</section>",nl(),nl()]).

mk_lvl_marker([C|Cs]) when $a =< C, C =< $z ->
    [C|mk_lvl_marker(Cs)];
mk_lvl_marker([C|Cs]) when $A =< C, C =< $Z ->
    [C|mk_lvl_marker(Cs)];
mk_lvl_marker([C|Cs]) when C == $ ; C == $\t ->
    [$-|mk_lvl_marker(Cs)];
mk_lvl_marker([_|Cs]) ->
    mk_lvl_marker(Cs);
mk_lvl_marker([]) ->
    [].

mk_marker([L|Ls]) ->
    mk_marker(Ls, L).

mk_marker([top], Res) ->
    Res;
mk_marker([L|Ls], Res) ->
    mk_marker(Ls, [L,$_|Res]).

header(#state{ofile = {File, _}} = S0, Title) ->
    {Year, Month, Day} = erlang:date(),
    S1 = put_line(S0, "<header>"),
    S2 = put_delayed(S1, ?DELAYED_COPYRIGHT_IX),
    S3 = put_chars(S2,
		   ["<title>", text(Title), "</title>", nl(),
		    "<prepared>emd2exml</prepared>", nl(),
		    "<responsible>emd2exml</responsible>", nl(),
		    "<docno>1</docno>", nl(),
		    "<approved>yes</approved>", nl(),
		    "<checked>yes</checked>", nl(),
		    "<date>",
		    integer_to_list(Year), "-",
		    integer_to_list(Month), "-",
		    integer_to_list(Day),
		    "</date>", nl(),
		    "<rev>1</rev>", nl(),
		    "<file>",File,"</file>", nl(),
		    "</header>", nl()]),
    put_delayed(S3, ?DELAYED_TOC_IX).


create_copyright_notice(#state{copyright_data = CRD} = S) ->
    {From, To, Holder, Legal} = parse_crd(CRD, [], [], [], []),
    write_delayed(S,
		  ?DELAYED_COPYRIGHT_IX,
		  ["<copyright>", nl(),
		   "<year>", From, "</year>", nl(),
		   "<year>", To, "</year>", nl(),
		   "<holder>", code(Holder),"</holder>", nl(),
		   "</copyright>", nl(),
		   "<legalnotice>", nl(),
		   code(Legal),
		   "</legalnotice>", nl(), nl()]).

create_toc(#state{toc = TOC} = S) ->
    case read_delayed(S, "?TOC") of
	{value,{"true",[]}} ->
	    write_delayed(S,
			  ?DELAYED_TOC_IX,
			  ["<p><strong>Table of Contents</strong></p>", nl(), TOC]);
	_ ->
	    write_delayed(S, ?DELAYED_TOC_IX, "")
    end.

parse_crd([], From, To, Holder, Legal) ->
    {Year, _, _} = erlang:date(),
    {case From of
	 [] -> integer_to_list(Year);
	 _ -> From
     end,
     case To of
	 [] -> integer_to_list(Year);
	 _ -> To
     end,
     case Holder of
	 [] -> "Ericsson AB. All Rights Reserved.";
	 _ -> Holder
     end,
     case Legal of
	 [] ->
             ["Licensed under the Apache License, Version 2.0 (the \"License\");", nl(),
              "you may not use this file except in compliance with the License.", nl(),
              "You may obtain a copy of the License at", nl(),
              nl(),
              "    http://www.apache.org/licenses/LICENSE-2.0", nl(),
              nl(),
              "Unless required by applicable law or agreed to in writing, software", nl(),
              "distributed under the License is distributed on an \"AS IS\" BASIS,", nl(),
              "WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.", nl(),
              "See the License for the specific language governing permissions and", nl(),
              "limitations under the License.", nl()];
	 _ -> Legal
     end};
parse_crd([Line|Lines], OldFrom, OldTo, OldHolder, Legal) ->
    case copyright_line(Line) of
	no -> parse_crd(Lines, OldFrom, OldTo, OldHolder, [code(Line)|Legal]);
	{From, To, Holder} -> parse_crd(Lines, From, To, code(Holder), Legal)
    end.

copyright_line(Line) ->
    case copyright_line(Line, start, [], []) of
	{From, To} -> {From, To, Line};
	_ -> no
    end.

copyright_line([], start, _, _) ->
    no;
copyright_line([], _, [], []) ->
    {[], []};
copyright_line([], _, F, []) ->
    Year = lists:reverse(F),
    {Year, Year};
copyright_line("opyright "++Cs, start, [], []) ->
    copyright_line(Cs, find_from, [], []);
copyright_line([_|Cs], start, [], []) ->
    copyright_line(Cs, start, [], []);
copyright_line([C|Cs], find_from, [], []) when $0 =< C, C =< $9 ->
    copyright_line(Cs, from, [C|[]], []);
copyright_line([_|Cs], find_from, [], []) ->
    copyright_line(Cs, find_from, [], []);
copyright_line([C|Cs], from, F, []) when $0 =< C, C =< $9 ->
    copyright_line(Cs, from, [C|F], []);
copyright_line([_|Cs], from, F, []) ->
    copyright_line(Cs, find_to, F, []);
copyright_line([C|Cs], find_to, F, []) when $0 =< C, C =< $9 ->
    copyright_line(Cs, to, F, [C|[]]);
copyright_line([_|Cs], find_to, F, []) ->
    copyright_line(Cs, find_to, F, []);
copyright_line([C|Cs], to, F, T) when  $0 =< C, C =< $9 ->
    copyright_line(Cs, to, F, [C|T]);
copyright_line(_, to, F, T) ->
    {lists:reverse(F), lists:reverse(T)}.

%%
%% Lists
%%

put_list_p(#state{list_p_stack = [{_, IX} | _]} = S, start) ->
    put_delayed(S#state{list_p = true}, IX);
put_list_p(#state{list_p_stack = [{_, IX} | _]} = S, stop) ->
    put_delayed(S#state{list_p = false}, IX+1).

list_use_p(#state{list_p_stack = [{unknown, IX} | LPS]} = S0, yes) ->
    S1 = write_delayed(S0, IX, "<p>"),
    S2 = write_delayed(S1, IX+1, "</p>"),
    S2#state{list_p_stack = [{yes, IX} | LPS]};
list_use_p(#state{list_p_stack = [{unknown, IX} | LPS]} = S0, no) ->
    S1 = write_delayed(S0, IX, ""),
    S2 = write_delayed(S1, IX+1, ""),
    S2#state{list_p_stack = [{no, IX} | LPS]};
list_use_p(S, _) ->
    S.

list_chk_nxt_line(#state{list_p = false} = S) ->
    S;
list_chk_nxt_line(#state{next_type = {text, _}} = S) ->
    S;
list_chk_nxt_line(S) ->
    put_line(put_list_p(S, stop), "").

list_item(#state{list_lvl = OldLvl} = S0, ListType, ListLvl) ->
    NewLvl = case ListLvl > OldLvl of
		 true -> OldLvl+1;
		 false -> ListLvl+1
	     end,
    S1 = chg_list_lvl(S0, ListType, NewLvl),
    case NewLvl =< OldLvl of
	false ->
	    S1;
	true ->
	    case S1#state.list_type_stack of
		[ListType|_] ->
		    %% New item in old list
		    put_chars(S1, ["</item>", nl(), "<item>", nl()]);
		[_|LTS] ->
		    %% New item in new list
		    [_ | LPS] = S1#state.list_p_stack,
		    IX = S1#state.delayed_array_ix,
		    S2 = list_use_p(S1, no), % Ignored if already determined
		    S3 = put_line(S2, list_end_tags()),
		    S4 = put_line(S3, list_begin_tags(ListType)),
		    S4#state{list_type_stack = [ListType|LTS],
			     list_p_stack = [{unknown, IX} | LPS],
			     delayed_array_ix = IX+2}
	    end
    end.

list_begin_tags(uolist) ->
    "<list type=\"bulleted\"><item>";
list_begin_tags(olist) ->
    "<list type=\"ordered\"><item>".

list_end_tags() ->
    "</item></list>".

chg_list_lvl(#state{list_lvl = Lvl} = S, Lvl) ->
    S;
chg_list_lvl(#state{list_lvl = OldLvl,
		    list_type_stack = [ListType|_]} = S,
	     NewLvl) when OldLvl > NewLvl ->
    chg_list_lvl(S, ListType, NewLvl).

chg_list_lvl(#state{list_lvl = Lvl} = S, _ListType, Lvl) ->
    S;
chg_list_lvl(#state{list_p_stack = LPS,
		    list_type_stack = LTS,
		    delayed_array_ix = IX,
		    list_lvl = OldLvl} = S,
	     ListType,
	     Lvl) when OldLvl < Lvl ->
    chg_list_lvl(put_line(S#state{list_type_stack = [ListType|LTS],
				  list_p_stack = [{unknown, IX} | LPS],
				  delayed_array_ix = IX+2,
				  list_lvl = OldLvl+1},
			  list_begin_tags(ListType)),
		 Lvl);
chg_list_lvl(#state{list_p_stack = [_ | LPS],
		    list_type_stack = [_|LTS],
		    list_lvl = OldLvl} = S0,
	     ListType,
	     Lvl) ->
    S1 = list_use_p(S0, no), % Ignored if already determined
    chg_list_lvl(put_line(S1#state{list_p_stack = LPS,
				   list_type_stack = LTS,
				   list_lvl = OldLvl-1},
			  list_end_tags()),
		 ListType,
		 Lvl).

list_strip(uolist, Str) ->
    case list_strip(Str) of
	[C | Cs] when C == $*; C == $+; C == $- ->
	    list_strip(Cs);
	_ ->
	    exit({unexpected_unordered_list_item, Str})
    end;
list_strip(olist, Str) ->
    case strip_head(list_strip(Str), lists:seq($0, $9)) of
	[$. | Cs] ->
	    list_strip(Cs);
	_ ->
	    exit({unexpected_ordered_list_item, Str})
    end.

list_strip(S) ->
    strip_head(S, [$ ,$\t]).

%%
%% Block quote
%%

rm_bquote(0, 0, Str) ->
    Str;
rm_bquote(0, BQLvl, [$>|Cs]) ->
    rm_bquote(0, BQLvl-1, Cs);
rm_bquote(0, BQLvl, [C|Cs]) when C == $ ; C == $\t ->
    rm_bquote(0, BQLvl, Cs);
rm_bquote(TxtLvl, BQLvl, "    " ++ Cs) ->
    "    " ++ rm_bquote(TxtLvl-1, BQLvl, Cs);
rm_bquote(TxtLvl, BQLvl, [$\t|Cs]) ->
    [$\t | rm_bquote(TxtLvl-1, BQLvl, Cs)].

chg_bq_lvl(Lvl, #state{bq_lvl = Lvl} = S) ->
    S;
chg_bq_lvl(NewLvl, #state{bq_lvl = Lvl} = S) when NewLvl > Lvl ->
    chg_bq_lvl(NewLvl,
	       put_line(end_p(end_code(S#state{bq_lvl = Lvl+1})), "<quote>"));
chg_bq_lvl(NewLvl, #state{bq_lvl = Lvl} = S) ->
    chg_bq_lvl(NewLvl,
	       put_line(end_p(end_code(S#state{bq_lvl = Lvl-1})), "</quote>")).

%%
%% Resolve link
%%

resolve_link(#state{line = Line} = S) ->
    {Key, Url, Title} = resolve_link(Line, start, "", "", ""),
    write_delayed(S, Key, {Url, Title}).

resolve_link("[" ++ Rest, start, "", "", "") ->
    resolve_link(Rest, key, "", "", "");
resolve_link([_|Cs], start, "", "", "") ->
    resolve_link(Cs, start, "", "", "");
resolve_link("]:" ++ Rest, key, Yek, "", "") ->
    resolve_link(Rest, url, Yek, "", "");
resolve_link([C|Cs], url, Yek, Lru, "") when C == $"; C == $' -> %"
    resolve_link(Cs, {title, C}, Yek, Lru, "");
resolve_link([$(|Cs], url, Yek, Lru, "") ->
    resolve_link(Cs, {title, $)}, Yek, Lru, "");
resolve_link([C|Cs], {title, C}, Yek, Lru, Eltit) ->
    resolve_link(Cs, drop, Yek, Lru, Eltit);
resolve_link([C|Cs], key, Yek, "", "") ->
    resolve_link(Cs, key, [C|Yek], "", "");
resolve_link([C|Cs], url, Yek, Lru, "") ->
    resolve_link(Cs, url, Yek, [C|Lru], "");
resolve_link([C|Cs], {title, _} = T, Yek, Lru, Eltit) ->
    resolve_link(Cs, T, Yek, Lru, [C|Eltit]);
resolve_link([_|Cs], drop, Yek, Lru, Eltit) ->
    resolve_link(Cs, drop, Yek, Lru, Eltit);
resolve_link([], _, Yek, Lru, Eltit) ->
    {ws_strip(lists:reverse(Yek)),
     ws_strip(md_strip_n_reverse(Lru)),
     ws_strip(lists:reverse(Eltit))}.

%% Remove .md at end of references.
md_strip_n_reverse(Lru) ->
    md_strip_n_reverse(Lru,[]).
md_strip_n_reverse("\ndm."++Lru,Acc) ->
    md_strip_n_reverse(Lru,Acc);
md_strip_n_reverse("#dm."++Lru,Acc) ->
    md_strip_n_reverse(Lru,[$#|Acc]);
md_strip_n_reverse([C|T],Acc) ->
    md_strip_n_reverse(T,[C|Acc]);
md_strip_n_reverse([], Acc) ->
    Acc.

%%
%% Misc
%%

ws_strip(S) ->
    strip(S, [$ ,$\t,$\n,$\r]).

%ws_strip_head(S) ->
%    strip_head(S, [$ ,$\t,$\n,$\r]).

%hws_strip_head(S) ->
%    strip_head(S, [$ ,$\t]).

%hws_strip(S) ->
%    strip(S, [$ ,$\t]).

strip([], _StripList) ->
    [];
strip([C|Cs] = Str, StripList) ->
    case lists:member(C, StripList) of
	true -> strip(Cs, StripList);
	false -> lists:reverse(pirts(lists:reverse(Str), StripList))
    end.

pirts([], _StripList) ->
    [];
pirts([C|Cs] = Str, StripList) ->
    case lists:member(C, StripList) of
	true -> pirts(Cs, StripList);
	false -> Str
    end.

strip_head([C|Cs] = Str, StripList) ->
    case lists:member(C, StripList) of
	true -> strip_head(Cs, StripList);
	false -> Str
    end.

type("[" ++ Cs) ->
    type_resolve_link(Cs);
type("   [" ++ Cs) ->
    type_resolve_link(Cs);
type("==" ++ Cs) ->
    case type_same(Cs, $=) of
	true -> {marker, h1};
	_ -> {text, 0}
    end;
type("--" ++ Cs) ->
    case type_same(Cs, $-) of
	true -> {marker, h2};
	_ -> {text, 0}
    end;
type(Str) ->
    type_cont(Str).

type_resolve_link([]) ->
    {text, 0};
type_resolve_link("]:" ++ _) ->
    resolve_link;
type_resolve_link([_|Cs]) ->
    type_resolve_link(Cs).

type_bquote(Str, N) ->
    case type(Str) of
	{bquote, N, M} ->
	    {bquote, N, M+1};
	_ ->
	    {bquote, N, 1}
    end.

type_same([C|Cs], C) ->
    type_same(Cs, C);
type_same([_|Cs], _) ->
    case type_cont(Cs) of
	blank -> true;
	_ -> false
    end.

type_cont(Str) ->
    type_cont(Str, 0, true).

type_cont("    " ++ Str, N, true) ->
    type_cont(Str, N+1, true);
type_cont([$\t| Str], N, true) ->
    type_cont(Str, N+1, true);
type_cont([C|Str], N, _) when C == $ ; C == $\t; C == $\n; C == $\r ->
    type_cont(Str, N, false);
type_cont([], _, _) ->
    blank;
type_cont(">" ++ Cs, N, _) ->
    type_bquote(Cs, N);
type_cont(" >" ++ Cs, N, _) ->
    type_bquote(Cs, N);
type_cont("  >" ++ Cs, N, _) ->
    type_bquote(Cs, N);
type_cont("   >" ++ Cs, N, _) ->
    type_bquote(Cs, N);
type_cont([C,$  |_], N, _) when C == $*; C == $+; C == $- ->
    {uolist, N};
type_cont([C,$\t |_], N, _) when C == $*; C == $+; C == $- ->
    {uolist, N};
type_cont([C|Cs], N, _) when $0 =< C, C =< $9 ->
    case type_olist(Cs) of
        true -> {olist, N};
        false -> {text, N}
    end;
type_cont("%CopyrightBegin%" ++ _, _, _) ->
    copyright_begin;
type_cont("%CopyrightEnd%" ++ _, _, _) ->
    copyright_end;
type_cont(_, N, _) ->
    {text, N}.

type_olist([C|Cs]) when $0 =< C, C =< $9 ->
    type_olist(Cs);
type_olist([$.,$ |_]) ->
    true;
type_olist([$.,$\t|_]) ->
    true;
type_olist(_) ->
    false.

end_all(S) ->
    chg_list_lvl(end_p(end_code(S)), 0).

get_line(#state{next_line = eof} = S) ->
    S#state{prev_line = S#state.line,
	    prev_type = S#state.type,
	    line = eof,
	    type = blank,
	    bq_type = 0};
get_line(#state{ifile = IFile, line_no = LNO, copyright = CR} = S0) ->
    NewLine = file_read_line(IFile, LNO),
    S1 = case {CR, type(NewLine)} of
	     {false, copyright_begin} ->
		 S0#state{copyright = true,
			  next_line = "",
			  next_type = blank};
	     {true, copyright_end} ->
		 S0#state{copyright = false,
			  next_line = "",
			  next_type = blank};
	     {true, NextType} ->
		 S0#state{next_line = NewLine,
			  next_type = NextType,
			  copyright_data = [NewLine|S0#state.copyright_data]};
	     {false, NextType} ->
		 S0#state{next_line = NewLine,
			  next_type = NextType}
	 end,
    S1#state{line_no = S0#state.line_no + 1,
	     line = S0#state.next_line,
	     type = S0#state.next_type,
	     bq_type = S0#state.bq_next_type,
	     prev_line = S0#state.line,
	     prev_type = S0#state.type,
	     bq_next_type = 0}.

write_delayed(#state{delayed_array = DA} = S,
	      IX,
	      Value) when is_integer(IX) ->
    S#state{delayed_array = array:set(IX, Value, DA)};
write_delayed(#state{delayed_tree = DT} = S, Key, Value) ->
    S#state{delayed_tree = gb_trees:enter(Key, Value, DT)}.

read_delayed(#state{delayed_array = DA}, IX) when is_integer(IX) ->
    array:get(IX, DA);
read_delayed(#state{delayed_tree = DT}, Key) ->
    gb_trees:lookup(Key, DT).

put_delayed(#state{out = Out} = S, Key) ->
    S#state{out = [{delayed, Key} | Out]}.

put_delayed(#state{out = Out} = S, Key, Data) ->
    S#state{out = [{delayed, Key, Data} | Out]}.

put_chars(#state{out = Out} = S, Chars) ->
    S#state{out = [[Chars] | Out]}.

put_line(#state{out = Out} = S, String) ->
    S#state{out = [[String, nl()] | Out]}.

complete_output(#state{out = Out} = S) ->
    complete_output(create_copyright_notice(create_toc(S)), Out, []).

complete_output(S, [], Out) ->
    S#state{delayed_array = [],
	    out = ["<?xml version=\"1.0\" encoding=\"UTF-8\" ?>", nl(),
		   "<!DOCTYPE chapter SYSTEM \"chapter.dtd\">", nl(),
		   Out]};
complete_output(S, [{delayed, IX}|Rest], Out) ->
    complete_output(S, Rest, [read_delayed(S, IX)|Out]);
complete_output(S, [{delayed, Key, {link, Text, Line}}|Rest], Out) ->
    case read_delayed(S, Key) of
	{value, {Url, _Title}} ->
	    complete_output(S, Rest, [mk_link(Text, Url)|Out]);
	none ->
	    {File, _} = S#state.ifile,
            ?ABORT("~s:~w - Link definition name `~ts' not found", [File,Line,Key])
    end;
complete_output(S, [{delayed, Key, {image, _Text, Line}}|Rest], Out) ->
    case read_delayed(S, Key) of
	{value, {Url, Title}} ->
	    complete_output(S, Rest, [mk_image(Title, Url)|Out]);
	none ->
	    {File, _} = S#state.ifile,
            ?ABORT("~s:~w - Image definition name `~ts' not found", [File,Line,Key])
    end;
complete_output(S, [Next|Rest], Out) ->
    complete_output(S, Rest, [Next|Out]).

write_output(_OFD, []) ->
    ok;
write_output(OFD, [O|Os]) ->
     file_write(OFD, O),
     write_output(OFD, Os).

%%
%% I/O
%%

nl() ->
    io_lib:nl().

file_wopen(File) ->
    case file:open(File, [write, delayed_write]) of
	{ok, FD} ->
            {File, FD};
	{error, Reason} ->
            ?ABORT("Failed to open `~s' for writing: ~p~n", [File, Reason])
    end.

file_ropen(File) ->
    case file:open(File, [read, binary]) of
	{ok, FD} ->
            {File, FD};
	{error, Reason} ->
            ?ABORT("Failed to open `~s' for reading: ~p~n", [File, Reason])
    end.

file_read_line({File, FD}, LineNo) ->
    case file:read_line(FD) of
	{ok, Line} -> unicode:characters_to_list(Line, utf8);
	eof -> eof;
	{error, Error} ->
            ?ABORT("~ts:~w - Reading line failed: ~p~n",[File,LineNo,Error])
    end.

file_write({File, FD}, Data) ->
    case file:write(FD, unicode:characters_to_binary(Data, unicode, utf8)) of
	ok -> ok;
	{error, Reason} ->
	    ?ABORT("Writing to file `~s' failed: ~p~n", [File, Reason])
    end.

file_close({File, FD}) ->
    case file:close(FD) of
	ok -> ok;
	{error, Reason} ->
            ?ABORT("Closing file `~s' failed: ~p~n",[File,Reason])
    end.
