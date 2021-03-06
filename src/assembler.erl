% a module devoted to de novo assembly of genome
%
% (c) Cloudozer, 2015
%


-module(assembler).
-export([start_worker/3,
		encode_G/1
		]).


%% worker builds a sub-graph and then returns it back to Pid
start_worker(Pid,Uid,{J,Read}) ->
	G_str = encode_G(Read),
	Gph = init(Uid,Read,J,G_str),
	worker(Pid,Uid,Gph,G_str).


worker(Pid,Uid,Gph,Prev_read) ->
	receive
		get_graph -> 
			io:format("Graph got ~p nodes~n",[length(digr:nodes(Gph))]),
			export_to_dot(Gph,"sembly"),
			Pid ! {graph,Gph}; 						%% sends graph to master and terminates
		{merge_to,Wid} -> {add_graph, Wid ! Gph}; 		%% sends graph to the other worker and terminates
		{add_graph,Gph1} -> 							%% merges a sub_graph and confirms that to master
			Pid ! {self(),merged},
			worker(Pid,Uid,merge_graphs(Gph,Gph1,Prev_read), Prev_read);
		{next_read,R_id,Read} -> 										%% tries to attach read and confirms the result to master
			case attach_read(Uid,Gph,R_id,Read) of
				{Size,Gph1} -> Pid ! {self(), Size}, worker(Pid,Uid,Gph1,Read);
				false -> Pid ! not_attached, worker(Pid,Uid,Gph,Read)
			end
	end.


% TODO: initialise the graph for a given Read
init(Uid,Seq,Pos,G_str) -> 
	digr:add_node(uid:next(Uid),[{g_string,G_str},{read,Seq},{loc,0},{pos,Pos}],digr:new()).



%% tries to attach a given Read to the graph
attach_read(Uid,{Nodes,_}=Gph,R_id,Read) ->
	G_str = encode_G(Read),
	%io:format("New read: ~p~n",[R_id]),
	%% try to attach the Read to top-level nodes of Gph
	Top_nodes = lists:filter(fun({Node_id,_}) -> length(digr:incidents(Node_id,Gph))==0 end, Nodes),
	%io:format("Top_nodes: ~w~n",[[ ID || {ID,_}<-Top_nodes]]),
	attach_read(Uid,Gph,R_id,Read,G_str,Top_nodes,[],false).

attach_read(Uid,Gph,R_id,Read,Read_str,[{Node_id,Attrs}|Nodes],Acc,Attached) ->
	{g_string,Graph_str} = lists:keyfind(g_string,1,Attrs),
	%io:format("g_string:~p~n",[Graph_str]),
	%io:format("read:    ~p~n",[Read_str]),
	case g_string:align(Read_str,Graph_str) of
		[] -> attach_read(Uid,Gph,R_id,Read,Read_str,Nodes,[{Node_id,Attrs}|Acc],Attached);
		Candidates ->
			%io:format("G-string matches: ~p~n",[Candidates]), 
			case add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Candidates) of
				false -> attach_read(Uid,Gph,R_id,Read,Read_str,Nodes,[{Node_id,Attrs}|Acc],Attached);
				Gph1 -> attach_read(Uid,Gph1,R_id,Read,Read_str,Nodes,[{Node_id,Attrs}|Acc],true)
			end
	end;

attach_read(Uid,Gph,R_id,Read,Read_str,[],Nodes,false) ->
	%% find all children nodes and continue search
	%io:format("read not aligned. Aligning to the children ...~n"),
	Children = lists:usort( lists:foldl(fun({Nid,_},Acc)-> digr:neighbors(Nid,Gph)++Acc
										end, [], Nodes)
	),

	%io:format("Children: ~p~n",[Children]),
	case Children of
		[] -> false;
		_ -> attach_read(Uid,Gph,R_id,Read,Read_str,Children,[],false)
	end;

attach_read(_,Gph,_,_,_,[],_,true) -> {digr:size(Gph),Gph}.



%% Checks if a read matches with Node at each position
%% if it does, it adds child and parent node
add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Candidates) ->
	add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Candidates,false).

add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,[Sh|Shifts],Attached) ->
	{read,G_read} = lists:keyfind(read,1,Attrs),
	R_body = lists:sum(Read_str),
	G_body = lists:sum(Graph_str),
	if
		Sh < R_body ->
			L = length(Read),
			Overlap = Sh + get_first_G(lists:reverse(Read)) + get_first_G(G_read) - 1,
			R = lists:sublist(Read,L-Overlap+1,Overlap),
			G = lists:sublist(G_read,Overlap),
			case R =:= G of
				true ->
					%io:format(" LEFT alignment~n"),
			
					{loc,Loc} = lists:keyfind(loc,1,Attrs),
					Loc1 = Loc + Overlap - length(Read),
					Kid_id = uid:next(Uid),
					Gph1 = digr:add_node(Kid_id,[{read,Read},{loc,Loc1},{g_string,Read_str},{pos,R_id}],Gph),

					%% add new parent node
					%io:format("~p~n~p~n",[Read,G_read]),
					Left_part = lists:sublist(Read,length(Read)-Overlap),
					Par_read = Left_part++G_read,
					io:format("New parent. Length: ~p~n",[length(Par_read)]),
					Par_id = uid:next(Uid),
					Gph2 = digr:add_node(Par_id,[{read,Par_read},
												{loc,Loc1},{g_string,encode_G(Par_read)}],Gph1),
					%% add two edges
					Gph3 = digr:add_edge({Par_id,Kid_id}, digr:add_edge({Par_id,Node_id},Gph2) ),
					add_parent_node(Uid,Gph3,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,true);

				false-> 
					add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,Attached)
			end;

		Sh =:= R_body andalso Sh =:= G_body -> 
			io:format(" CENTER alignment~n"),
			add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,Attached);

		Sh =:= R_body -> 
			io:format(" CENTER alignment~n"),
			add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,Attached);

		Sh =:= G_body -> 
			io:format(" CENTER alignment~n"),
			add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,Attached);

		Sh < G_body -> % Shift is larger than Read
			io:format(" CENTER alignment~n"),
			add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,Attached);

		Sh > G_body -> 
			L = length(G_read),
			%io:format("Bodies:~p, ~p~n",[G_body,R_body]),
			%io:format("Shift:~p~n",[Sh]),
			Overlap = R_body + G_body - Sh + get_first_G(Read) + get_first_G(lists:reverse(G_read)) - 1,
			%io:format("Overlap:~p~n",[Overlap]),
			G = lists:sublist(G_read,L-Overlap+1,Overlap),
			R = lists:sublist(Read,Overlap),
			%io:format("~p~n~p~n",[G,R]),
			case R =:= G of
				true ->
					%io:format(" RIGHT alignment~n"),
			
					{loc,Loc} = lists:keyfind(loc,1,Attrs),
					Loc1 = Loc - Overlap + length(G_read),
					Kid_id = uid:next(Uid),
					Gph1 = digr:add_node(Kid_id,[{read,Read},{loc,Loc1},{g_string,Read_str},{pos,R_id}],Gph),

					%% add new parent node
					%io:format("~p~n~p~n",[Read,G_read]),
					Left_part = lists:sublist(Read,length(Read)-Overlap),
					Par_read = Left_part++G_read,
					io:format("New parent. Length: ~p~n",[length(Par_read)]),
					Par_id = uid:next(Uid),
					Gph2 = digr:add_node(Par_id,[{read,Par_read},
												{loc,Loc},{g_string,encode_G(Par_read)}],Gph1),
					%% add two edges
					Gph3 = digr:add_edge({Par_id,Kid_id}, digr:add_edge({Par_id,Node_id},Gph2) ),
					add_parent_node(Uid,Gph3,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,true);

				false-> 
					add_parent_node(Uid,Gph,Node_id,Graph_str,Attrs,R_id,Read,Read_str,Shifts,Attached)
			end;


			
		true ->
			io:format("G_body:~p, R_body:~p, Shift:~p~n",[G_body,R_body,Sh]), 
			throw(impossible_case)
	end;
	
add_parent_node(_,Gph,_,_,_,_,_,_,[],true) -> Gph;
add_parent_node(_,_,_,_,_,_,_,_,[],false) -> false.




merge_graphs(Gph1,Gph2,Read) -> 
	io:format("~p,~p~n",[Gph2,Read]),
	Gph1.  %% TODO.
	


get_first_G(Str) -> get_first_G(Str,1).
get_first_G([$G|_],Count) -> Count;
get_first_G([_|Str],Count) -> get_first_G(Str,Count+1).



encode_G(Read) -> encode_G(Read,1,[]).

encode_G([$G|Read],Count,Acc) -> encode_G(Read,1,[Count|Acc]);
encode_G([_|Read],Count,Acc) -> encode_G(Read,Count+1,Acc);
encode_G([],_,Acc) -> [_|G_str] = lists:reverse(Acc), G_str.



export_to_dot(Gr,Gname) ->
	File = Gname++".dot",
	{ok,Out} = file:open(File, [write]),
	io:format(Out, "digraph ~s {~n",[Gname]),
	{Nodes,_} = Gr,
	export_to_dot(Nodes,digr:edges(Gr),Out).	
	 
export_to_dot(_,[],Out) ->
	io:format(Out,"}",[]),
	file:close(Out);
export_to_dot(Nodes,[{Nd1,Nd2}|Edges],Out) ->
	{Nd1,Attr1} = lists:keyfind(Nd1,1,Nodes),
	{read,N1} = lists:keyfind(read,1,Attr1),
	{Nd2,Attr2} = lists:keyfind(Nd2,1,Nodes),
	{read,N2} = lists:keyfind(read,1,Attr2),

	io:format(Out,"\"~s\" -> \"~s\" ;~n",[short(N1),short(N2)]),
	export_to_dot(Nodes,Edges,Out).


short(Str) when length(Str)=<10 -> Str++"  "++str(length(Str));
short(Str) -> lists:sublist(Str,5)++".."++lists:sublist(Str,length(Str)-4,5)++"  "++str(length(Str)).


str(S) -> integer_to_list(S).