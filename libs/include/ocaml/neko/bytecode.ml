
type opcode =
	(* getters *)
	| AccNull
	| AccTrue
	| AccFalse
	| AccThis
	| AccInt of int
	| AccStack of int
	| AccGlobal of int
	| AccEnv of int
	| AccField of string
	| AccArray
	| AccBuiltin of int
	(* setters *)
	| SetStack of int
	| SetGlobal of int
	| SetEnv of int
	| SetField of string
	| SetArray
	(* stack ops *)
	| Push
	| Pop of int
	| Call of int
	| ObjCall of int
	| Jump of int
	| JumpIf of int
	| JumpIfNot of int
	| Trap of int
	| EndTrap
	| Ret
	| MakeEnv of int
	(* value ops *)
	| Bool
	| Add
	| Sub
	| Mult
	| Div
	| Mod
	| Shl
	| Shr
	| UShr
	| Eq
	| Neq
	| Gt
	| Gte
	| Lt
	| Lte

type global =
	| GlobalVar of string
	| GlobalFunction of int
	| GlobalString of string
	| GlobalFloat of string

exception Invalid_file

let hash_field s =
	let acc = ref 0 in
	for i = 0 to String.length s - 1 do
		acc := 223 * !acc + Char.code (String.unsafe_get s i)
	done;
	acc := !acc land ((1 lsl 31) - 1);
	!acc	

let op_param = function
	| AccInt _
	| AccStack _
	| AccGlobal _
	| AccEnv _
	| AccField _
	| AccBuiltin _
	| SetStack _
	| SetGlobal _
	| SetEnv _
	| SetField _
	| Pop _
	| Call _
	| ObjCall _
	| Jump _
	| JumpIf _
	| JumpIfNot _
	| Trap _
	| MakeEnv _ 
		-> true
	| AccNull
	| AccTrue
	| AccFalse
	| AccThis
	| AccArray
	| SetArray
	| Push
	| EndTrap
	| Ret
	| Bool
	| Add
	| Sub
	| Mult
	| Div
	| Mod
	| Shl
	| Shr
	| UShr
	| Eq
	| Neq
	| Gt
	| Gte
	| Lt
	| Lte
		-> false

let code_tables ops =
	let ids = Hashtbl.create 0 in
	Array.iter (function
		| AccField s
		| SetField s ->
			let id = hash_field s in
			(try
				let f = Hashtbl.find ids id in
				if f <> s then failwith ("Field hashing conflict " ^ s ^ " and " ^ f);
			with
				Not_found ->	
					Hashtbl.add ids id s)
		| _ -> ()
	) ops;
	let p = ref 0 in
	let pos = Array.map (fun op ->
		let h = !p in
		p := h + (if op_param op then 2 else 1);
		!p
	) ops in
	ids , pos , !p

let write ch (globals,ops) =
	IO.nwrite ch "NEKO";
	let globals = DynArray.of_array globals in
	let ids , pos , csize = code_tables ops in
	IO.write_i32 ch (DynArray.length globals);
	IO.write_i32 ch (Hashtbl.length ids);
	IO.write_i32 ch csize;
	DynArray.iter (function
		| GlobalVar s -> IO.write_byte ch 1; IO.nwrite ch s; IO.write ch '\000';
		| GlobalFunction p -> IO.write_byte ch 2; IO.write_i32 ch pos.(p)
		| GlobalString s -> IO.write_byte ch 3; IO.write_ui16 ch (String.length s); IO.nwrite ch s
		| GlobalFloat s -> IO.write_byte ch 3; IO.nwrite ch s; IO.write ch '\000'
	) globals;
	Hashtbl.iter (fun _ s ->
		IO.nwrite ch s;
		IO.write ch '\000';
	) ids;
	Array.iteri (fun i op ->
		let pop = ref None in
		let opid = (match op with
			| AccNull -> 0
			| AccTrue -> 1
			| AccFalse -> 2
			| AccThis -> 3
			| AccInt n -> pop := Some n; 4
			| AccStack n -> pop := Some n; 5
			| AccGlobal n -> pop := Some n; 6
			| AccEnv n -> pop := Some n; 7
			| AccField s -> pop := Some (hash_field s); 8
			| AccArray -> 9
			| AccBuiltin n -> pop := Some n; 10
			| SetStack n -> pop := Some n; 11
			| SetGlobal n -> pop := Some n; 12
			| SetEnv n -> pop := Some n; 13
			| SetField s -> pop := Some (hash_field s); 14
			| SetArray -> 15
			| Push -> 16
			| Pop n -> pop := Some n; 17
			| Call n -> pop := Some n; 18
			| ObjCall n -> pop := Some n; 19
			| Jump n -> pop := Some (pos.(i+n) - pos.(i)); 20
			| JumpIf n -> pop := Some (pos.(i+n) - pos.(i)); 21
			| JumpIfNot n -> pop := Some (pos.(i+n) - pos.(i)); 22
			| Trap n -> pop := Some (pos.(i+n) - pos.(i)); 23
			| EndTrap -> 24
			| Ret -> 25
			| MakeEnv n -> pop := Some n; 26
			| Bool -> 27
			| Add -> 28
			| Sub -> 29
			| Mult -> 30
			| Div -> 31
			| Mod -> 32
			| Shl -> 33
			| Shr -> 34
			| UShr -> 35
			| Eq -> 36
			| Neq -> 37
			| Gt -> 38
			| Gte -> 39
			| Lt -> 40
			| Lte -> 41
		) in
		match !pop with
		| None -> IO.write_byte ch (opid lsl 2)
		| Some n when opid < 32 && (n = 0 || n = 1) -> IO.write_byte ch ((opid lsl 3) lor (n lsl 2) lor 1)
		| Some n when n >= 0 && n <= 0xFF -> IO.write_byte ch ((opid lsl 2) lor 2); IO.write_byte ch n
		| Some n -> IO.write_byte ch ((opid lsl 2) lor 3); IO.write_i32 ch n
	) ops

let read_string ch =
	let b = Buffer.create 5 in
	let rec loop() =
		let c = IO.read ch in
		if c = '\000' then
			Buffer.contents b
		else begin
			Buffer.add_char b c;
			loop()
		end;
	in
	loop()

let read ch =
	try
		let head = IO.nread ch 4 in
		if head <> "NEKO" then raise Invalid_file;
		let nglobals = IO.read_i32 ch in
		let nids = IO.read_i32 ch in
		let csize = IO.read_i32 ch in
		if nglobals < 0 || nglobals > 0xFFFF || nids < 0 || nids > 0xFFFF || csize < 0 || csize > 0xFFFFFF then raise Invalid_file;
		let globals = Array.init nglobals (fun _ ->
			match IO.read_byte ch with
			| 1 -> GlobalVar (read_string ch)
			| 2 -> GlobalFunction (IO.read_i32 ch)
			| 3 -> let len = IO.read_ui16 ch in GlobalString (IO.nread ch len)
			| 4 -> GlobalFloat (read_string ch)
			| _ -> raise Invalid_file
		) in
		let ids = Hashtbl.create 0 in
		let rec loop n = 
			if n = 0 then
				()
			else
				let s = read_string ch in
				let id = hash_field s in
				try
					let s2 = Hashtbl.find ids id in
					if s <> s2 then raise Invalid_file;
				with
					Not_found ->
						Hashtbl.add ids id s;
						loop (n-1)
		in
		loop nids;
		let pos = Array.create csize (-1) in
		let cpos = ref 0 in
		let jumps = ref [] in
		let ops = DynArray.create() in
		while !cpos < csize do
			let code = IO.read_byte ch in
			let op , p = (match code land 3 with
				| 0 -> code lsr 2 , 0
				| 1 -> code lsr 3 , ((code lsr 2) land 1)
				| 2 -> code lsr 2 , IO.read_byte ch
				| 3 -> code lsr 3 , IO.read_i32 ch
				| _ -> assert false
			) in
			let op = (match op with
				| 0 -> AccNull
				| 1 -> AccTrue
				| 2 -> AccFalse
				| 3 -> AccThis
				| 4 -> AccInt p
				| 5 -> AccStack p
				| 6 -> AccGlobal p
				| 7 -> AccEnv p
				| 8 -> AccField (try Hashtbl.find ids p with Not_found -> raise Invalid_file)
				| 9 -> AccArray
				| 10 -> AccBuiltin p
				| 11 -> SetStack p
				| 12 -> SetGlobal p
				| 13 -> SetEnv p
				| 14 -> SetField (try Hashtbl.find ids p with Not_found -> raise Invalid_file)
				| 15 -> SetArray
				| 16 -> Push
				| 17 -> Pop p
				| 18 -> Call p
				| 19 -> ObjCall p
				| 20 -> jumps := (!cpos , DynArray.length ops) :: !jumps; Jump p
				| 21 -> jumps := (!cpos , DynArray.length ops) :: !jumps; JumpIf p
				| 22 -> jumps := (!cpos , DynArray.length ops) :: !jumps; JumpIfNot p
				| 23 -> jumps := (!cpos , DynArray.length ops) :: !jumps; Trap p
				| 24 -> EndTrap
				| 25 -> Ret
				| 26 -> MakeEnv p
				| 27 -> Bool
				| 28 -> Add
				| 29 -> Sub
				| 30 -> Mult
				| 31 -> Div
				| 32 -> Mod
				| 33 -> Shl
				| 34 -> Shr
				| 35 -> UShr
				| 36 -> Eq
				| 37 -> Neq
				| 38 -> Gt
				| 39 -> Gte
				| 40 -> Lt
				| 41 -> Lte
				| _ -> raise Invalid_file
			) in
			pos.(!cpos) <- DynArray.length ops;
			cpos := !cpos + (if op_param op then 2 else 1);
			DynArray.add ops op;
		done;
		if !cpos <> csize then raise Invalid_file;
		let pos_index i sadr =
			let idx = pos.(sadr) in
			if idx = -1 then raise Invalid_file;
			idx - i
		in
		List.iter (fun (a,i) ->
			DynArray.set ops i (match DynArray.get ops i with
			| Jump p -> Jump (pos_index i (a+p))
			| JumpIf p -> JumpIf (pos_index i (a+p))
			| JumpIfNot p -> JumpIfNot (pos_index i (a+p))
			| Trap p -> Trap (pos_index i (a+p))
			| _ -> assert false)			
		) !jumps;
		Array.iteri (fun i g ->
			match g with
			| GlobalFunction f -> globals.(i) <- GlobalFunction (pos_index 0 f)
			| _ -> ()
		) globals;
		globals , DynArray.to_array ops
	with
		| IO.No_more_input
		| IO.Overflow _ -> raise Invalid_file

let escape str =
	String.escaped str

let dump ch (globals,ops) =
	let ids, pos , csize = code_tables ops in
	IO.printf ch "nglobals : %d\n" (Array.length globals);
	IO.printf ch "nfields : %d\n" (Hashtbl.length ids);
	IO.printf ch "codesize : %d (%d)\n" (Array.length ops) csize;
	IO.printf ch "GLOBALS =\n";
	Array.iteri (fun i g ->
		IO.printf ch "  global %d : %s\n" i 
			(match g with
			| GlobalVar s -> "var " ^ s
			| GlobalFunction i -> "function " ^ string_of_int i
			| GlobalString s -> "string \"" ^ escape s ^ "\""
			| GlobalFloat s -> "float " ^ s)
	) globals;
	IO.printf ch "FIELDS =\n";
	Hashtbl.iter (fun h f ->
		IO.printf ch "  %s (%d)\n" f h;
	) ids;
	IO.printf ch "CODE =\n";
	let str s i = s ^ " " ^ string_of_int i in
	Array.iteri (fun pos op ->
		IO.printf ch "%6d    %s\n" pos (match op with
			| AccNull -> "AccNull"
			| AccTrue -> "AccTrue"
			| AccFalse -> "AccFalse"
			| AccThis -> "AccThis"
			| AccInt i -> str "AccInt" i
			| AccStack i -> str "AccStack" i
			| AccGlobal i -> str "AccGlobal" i
			| AccEnv i -> str "AccEnv" i
			| AccField s -> "AccField " ^ s
			| AccArray -> "AccArray"
			| AccBuiltin i -> str "AccBuiltin" i ^ " : " ^ (try fst (List.nth Ast.builtins_list i) with _ -> "???")
			| SetStack i -> str "SetStack" i
			| SetGlobal i -> str "SetGlobal" i
			| SetEnv i -> str "SetEnv" i
			| SetField f -> "SetField " ^ f
			| SetArray -> "SetArray"
			| Push -> "Push"
			| Pop i -> str "Pop" i
			| Call i -> str "Call" i
			| ObjCall i -> str "ObjCall" i
			| Jump i -> str "Jump" (pos + i)
			| JumpIf i -> str "JumpIf" (pos + i)
			| JumpIfNot i -> str "JumpIfNot" (pos + i)
			| Trap i -> str "Trap" (pos + i)
			| EndTrap -> "EndTrap"
			| Ret -> "Ret"
			| MakeEnv i -> str "MakeEnv" i
			| Bool -> "Bool"
			| Add -> "Add"
			| Sub -> "Sub" 
			| Mult -> "Mult"
			| Div -> "Div"
			| Mod -> "Mod"
			| Shl -> "Shl"
			| Shr -> "Shr"
			| UShr -> "UShr"
			| Eq -> "Eq"
			| Neq -> "Neq"
			| Gt -> "Gt"
			| Gte -> "Gte"
			| Lt -> "Lt"
			| Lte -> "Lte"
		)
	) ops;
	IO.printf ch "END\n"

