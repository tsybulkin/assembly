% a module devoted to de novo assembly of genome
%
% (c) Cloudozer, 2015
%


-module(sembly).
-export([t/0]).

-define(WORKERS_NBR,2).
-define(X_TRIALS,5). 	%% number of times a read will be tried to attach to the graph



t() ->
	Chromo = "GL000207.1",
	t(Chromo,100).

t(Chromo, Len) ->
	Coverage = 7,
	{ok,Ref} = file:read_file("data/"++Chromo++".ref"),
	D = round(2*Len/Coverage),
	io:format("Max distance between reads: ~p~n",[D]),
	Entire_seq = binary_to_list(Ref),
	
	Uid = uid:init(),
	Reads = get_reads(Entire_seq,D,Len,0,[]),
	%io:format("Reads: ~p~n",[Reads]),
	assemble(Reads,Uid),
	uid:stop(Uid).
	%io:format("~p~n",[Reads]).


get_reads(Entire_seq,D,Len,_,Acc) when length(Entire_seq) =< Len+D -> 
	[ {Pos,R} || {_,Pos,R} <- 
		lists:sort( [{random:uniform(),
					length(Entire_seq)-Len,
					lists:nthtail(length(Entire_seq)-Len,Entire_seq)} | Acc] )
	];
get_reads(Entire_seq,D,Len,J,Acc) ->
	D1 = random:uniform(D),
	get_reads(lists:nthtail(D1,Entire_seq),D,Len,J+D1,[{random:uniform(),J+D1,lists:sublist(Entire_seq,D1+1,Len)}|Acc]).



assemble([R|Reads],Uid) ->
	Pid = spawn(assembler,start_worker,[self(),Uid,R]),
	build_graph(queue:from_list(Reads),[Pid],length(Reads)*?X_TRIALS).
	


build_graph(Q,Workers,0) ->
	io:format("~p reads were not matched~n",[queue:len(Q)]),
	[ Pid ! get_graph || Pid <- Workers ],
	assemble_graph(length(Workers),[]);

build_graph(Q,Workers,N) ->
	case queue:out(Q) of
		{{value,Read},Q1} -> 
			build_graph(Q1,Workers,Read,N);
		{empty,_} -> 
			[ Pid ! get_graph || Pid <- Workers ],
			io:format("Assembling graph...~n~p~n",[Workers]),
			assemble_graph(length(Workers),[])
	end.
	
build_graph(Q,Workers,{Pos,Read},N) -> 
	%% sends Read to all workers which then try to attach it to their sub-graphs
	lists:foreach(fun(Wpid) -> Wpid ! {next_read,Pos,Read} end, Workers),
	Res = [ receive Msg -> Msg end || _ <- Workers ],
	%io:format("Got messages from ~p workers: ~p~n",[length(Res),Res]),
	
	%% if Read attached at more than one subgraphs -> merge these sub_graphs
	%% if Read attached at no subgraphs -> spawn a new worker or put the Read back in the queue
	L = length(lists:filter(fun(not_attached)->false; (_)->true end,Res)),
	case L of 
		0 -> 	%% spawn a new assembler or put Read back to the queue
			%io:format("Read did not match~n"),
			Q1 = queue:in({Pos,Read},Q),
			build_graph(Q1,Workers,N-1);
		1 -> 
			io:format("read attached to the only subgraph~n"),
			build_graph(Q,Workers,N);
		2 -> 
			io:format("Merge subgraphs~n"),
			build_graph(Q,Workers,N);
		_ ->
			io:format("L:~p~n",[L])
	end.
	



%% collect all sub-graphs
assemble_graph(0,Acc) -> Acc;
assemble_graph(Workers_nbr,Acc) -> receive {graph,Graph} -> assemble_graph(Workers_nbr-1, [Graph|Acc]) end.





