(********************************************************************)
(*                                                                  *)
(*  The LustreC compiler toolset   /  The LustreC Development Team  *)
(*  Copyright 2012 -    --   ONERA - CNRS - INPT                    *)
(*                                                                  *)
(*  LustreC is free software, distributed WITHOUT ANY WARRANTY      *)
(*  under the terms of the GNU Lesser General Public License        *)
(*  version 2.1.                                                    *)
(*                                                                  *)
(********************************************************************)

open Format
open Log

open Utils
open LustreSpec
open Compiler_common

let usage = "Usage: lustrec [options] <source-file>"

let extensions = [".ec"; ".lus"; ".lusi"]

(* print a .lusi header file from a source prog *)
let print_lusi prog dirname basename extension =
  let header = Lusic.extract_header dirname basename prog in
  let header_name = dirname ^ "/" ^ basename ^ extension in
  let h_out = open_out header_name in
  let h_fmt = formatter_of_out_channel h_out in
  begin
    Typing.uneval_prog_generics header;
    Clock_calculus.uneval_prog_generics header;
    Printers.pp_lusi_header h_fmt basename header;
    close_out h_out
  end

(* compile a .lusi header file *)
let compile_header dirname  basename extension =
  let destname = !Options.dest_dir ^ "/" ^ basename in
  let header_name = basename ^ extension in
  let lusic_ext = extension ^ "c" in
  begin
    Log.report ~level:1 (fun fmt -> fprintf fmt "@[<v>");
    let header = parse_header true (dirname ^ "/" ^ header_name) in
    ignore (Modules.load_header ISet.empty header);
    ignore (check_top_decls header);
    create_dest_dir ();
    Log.report ~level:1
      (fun fmt -> fprintf fmt ".. generating compiled header file %sc@," (destname ^ extension));
    Lusic.write_lusic true header destname lusic_ext;
    Lusic.print_lusic_to_h destname lusic_ext;
    Log.report ~level:1 (fun fmt -> fprintf fmt ".. done !@ @]@.")
  end

(* check whether a source file has a compiled header,
   if not, generate the compiled header *)
let compile_source_to_header prog computed_types_env computed_clocks_env dirname basename extension =
  let destname = !Options.dest_dir ^ "/" ^ basename in
  let lusic_ext = extension ^ "c" in
  let header_name = destname ^ lusic_ext in
  begin
    if not (Sys.file_exists header_name) then
      begin
	Log.report ~level:1 (fun fmt -> fprintf fmt ".. generating compiled header file %s@," header_name);
	Lusic.write_lusic false (Lusic.extract_header dirname basename prog) destname lusic_ext;
	Lusic.print_lusic_to_h destname lusic_ext
      end
    else
      let lusic = Lusic.read_lusic destname lusic_ext in
      if not lusic.Lusic.from_lusi then
	begin
	  Log.report ~level:1 (fun fmt -> fprintf fmt ".. generating compiled header file %s@," header_name);
       	  Lusic.write_lusic false (Lusic.extract_header dirname basename prog) destname lusic_ext;
	  (*List.iter (fun top_decl -> Format.eprintf "lusic: %a@." Printers.pp_decl top_decl) lusic.Lusic.contents;*)
	  Lusic.print_lusic_to_h destname lusic_ext
	end
      else
	begin
	  Log.report ~level:1 (fun fmt -> fprintf fmt ".. loading compiled header file %s@," header_name);
	  Modules.check_dependency lusic destname;
	  let header = lusic.Lusic.contents in
	  let (declared_types_env, declared_clocks_env) = get_envs_from_top_decls header in
	  check_compatibility
	    (prog, computed_types_env, computed_clocks_env)
	    (header, declared_types_env, declared_clocks_env)
	end
  end



(* compile a .lus source file *)
let rec compile_source dirname basename extension =

  Log.report ~level:1 (fun fmt -> fprintf fmt "@[<v>");

  (* Parsing source *)
  let prog = parse_source (dirname ^ "/" ^ basename ^ extension) in

  (* Removing automata *)
  let prog = Automata.expand_decls prog in

  Log.report ~level:4 (fun fmt -> fprintf fmt "After automata expansion:@.@[<v 2>@ %a@]@," Printers.pp_prog prog);

  (* Importing source *)
  let _ = Modules.load_program ISet.empty prog in

  (* Extracting dependencies *)
  let dependencies, type_env, clock_env = import_dependencies prog in

  (* Sorting nodes *)
  let prog = SortProg.sort prog in

  (* Perform inlining before any analysis *)
  let orig, prog =
    if !Options.global_inline && !Options.main_node <> "" then
      (if !Options.witnesses then prog else []),
      Inliner.global_inline basename prog type_env clock_env
    else (* if !Option.has_local_inline *)
      [],
      Inliner.local_inline basename prog type_env clock_env
  in

  (* Checking stateless/stateful status *)
  check_stateless_decls prog;

  (* Typing *)
  let computed_types_env = type_decls type_env prog in

  (* Clock calculus *)
  let computed_clocks_env = clock_decls clock_env prog in

  (* Generating a .lusi header file only *)
  if !Options.lusi then
    begin
      let lusi_ext = extension ^ "i" in
      Log.report ~level:1 (fun fmt -> fprintf fmt ".. generating interface file %s@," (dirname ^ "/" ^ basename ^ lusi_ext));
      print_lusi prog dirname basename lusi_ext;
      Log.report ~level:1 (fun fmt -> fprintf fmt ".. done !@ @]@.");
      exit 0
    end;

  (* Delay calculus *)
  (* TO BE DONE LATER (Xavier)
    if(!Options.delay_calculus)
    then
    begin
    Log.report ~level:1 (fun fmt -> fprintf fmt ".. initialisation analysis@?");
    try
    Delay_calculus.delay_prog Basic_library.delay_env prog
    with (Delay.Error (loc,err)) as exc ->
    Location.print loc;
    eprintf "%a" Delay.pp_error err;
    Utils.track_exception ();
    raise exc
    end;
  *)

  (* Creating destination directory if needed *)
  create_dest_dir ();

  (* Compatibility with Lusi *)
  (* Checking the existence of a lusi (Lustre Interface file) *)
  (match !Options.output with
    "C" ->
      begin
        let extension = ".lusi" in
        compile_source_to_header prog computed_types_env computed_clocks_env dirname basename extension;
      end
   |_ -> ());

  Typing.uneval_prog_generics prog;
  Clock_calculus.uneval_prog_generics prog;

  if !Options.global_inline && !Options.main_node <> "" && !Options.witnesses then
    begin
      let orig = Corelang.copy_prog orig in
      Log.report ~level:1 (fun fmt -> fprintf fmt ".. generating witness file@,");
      check_stateless_decls orig;
      let _ = Typing.type_prog type_env orig in
      let _ = Clock_calculus.clock_prog clock_env orig in
      Typing.uneval_prog_generics orig;
      Clock_calculus.uneval_prog_generics orig;
      Inliner.witness
	basename
	!Options.main_node
	orig prog type_env clock_env
    end;

(*Format.eprintf "Inliner.global_inline<<@.%a@.>>@." Printers.pp_prog prog;*)
  (* Computes and stores generic calls for each node,
     only useful for ANSI C90 compliant generic node compilation *)
  if !Options.ansi then Causality.NodeDep.compute_generic_calls prog;
  (*Hashtbl.iter (fun id td -> match td.Corelang.top_decl_desc with Corelang.Node nd -> Format.eprintf "%s calls %a" id Causality.NodeDep.pp_generic_calls nd | _ -> ()) Corelang.node_table;*)

  (* Normalization phase *)
  Log.report ~level:1 (fun fmt -> fprintf fmt ".. normalization@,");
  (* Special treatment of arrows in lustre backend. We want to keep them *)
  if !Options.output = "lustre" then
    Normalization.unfold_arrow_active := false;
  let prog = Normalization.normalize_prog prog in

  Log.report ~level:2 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@," Printers.pp_prog prog);
  (* Checking array accesses *)
  if !Options.check then
    begin
      Log.report ~level:1 (fun fmt -> fprintf fmt ".. array access checks@,");
      Access.check_prog prog;
    end;

  (* Computation of node equation scheduling. It also breaks dependency cycles
     and warns about unused input or memory variables *)
  Log.report ~level:1 (fun fmt -> fprintf fmt ".. scheduling@,");
  let prog, node_schs = Scheduling.schedule_prog prog in
  Log.report ~level:1 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@," Scheduling.pp_warning_unused node_schs);
  Log.report ~level:3 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@," Scheduling.pp_schedule node_schs);
  Log.report ~level:3 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@," Scheduling.pp_fanin_table node_schs);
  Log.report ~level:3 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@," Printers.pp_prog prog);

 (* Optimization of prog:
    - Unfold consts
    - eliminate trivial expressions
 *)
  let prog =
    if !Options.optimization >= 5 then
      begin
	Log.report ~level:1 (fun fmt -> fprintf fmt ".. constants elimination@,");
	Optimize_prog.prog_unfold_consts prog
      end
    else
      prog
  in
  (* DFS with modular code generation *)
  Log.report ~level:1 (fun fmt -> fprintf fmt ".. machines generation@,");
  let machine_code = Machine_code.translate_prog prog node_schs in

  Log.report ~level:2 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@,"
  (Utils.fprintf_list ~sep:"@ " Machine_code.pp_machine)
  machine_code);

  (* Optimize machine code *)
  let machine_code =
    if !Options.optimization >= 4 && !Options.output <> "horn" then
      begin
	Log.report ~level:1 (fun fmt -> fprintf fmt ".. machines optimization (phase 3)@,");
	Optimize_machine.machines_cse machine_code
      end
    else
      machine_code
  in

  (* Optimize machine code *)
  let machine_code =
    if !Options.optimization >= 2 && !Options.output <> "horn" then
      begin
	Log.report ~level:1 (fun fmt -> fprintf fmt ".. machines optimization (phase 1)@,");
	Optimize_machine.machines_unfold (Corelang.get_consts prog) node_schs machine_code
      end
    else
      machine_code
  in
  (* Optimize machine code *)
  let machine_code =
    if !Options.optimization >= 3 && !Options.output <> "horn" then
      begin
	Log.report ~level:1 (fun fmt -> fprintf fmt ".. machines optimization (phase 2)@,");
	Optimize_machine.machines_fusion (Optimize_machine.machines_reuse_variables machine_code node_schs)
      end
    else
      machine_code
  in

  if !Options.optimization >= 2 then
    begin
      Log.report ~level:3 (fun fmt -> fprintf fmt "@[<v 2>@ %a@]@,"
	(Utils.fprintf_list ~sep:"@ " Machine_code.pp_machine)
	machine_code);
    end;

  (* Printing code *)
  let basename    =  Filename.basename basename in
  let destname = !Options.dest_dir ^ "/" ^ basename in
  let _ = match !Options.output with
    | "C" ->
      begin
	  let alloc_header_file = destname ^ "_alloc.h" in (* Could be changed *)
	  let source_lib_file = destname ^ ".c" in (* Could be changed *)
	  let source_main_file = destname ^ "_main.c" in (* Could be changed *)
	  let makefile_file = destname ^ ".makefile" in (* Could be changed *)
	  Log.report ~level:1 (fun fmt -> fprintf fmt ".. C code generation@,");
	  C_backend.translate_to_c
	    alloc_header_file source_lib_file source_main_file makefile_file
	    basename prog machine_code dependencies
	end
    | "java" ->
      begin
	failwith "Sorry, but not yet supported !"
    (*let source_file = basename ^ ".java" in
      Log.report ~level:1 (fun fmt -> fprintf fmt ".. opening file %s@,@?" source_file);
      let source_out = open_out source_file in
      let source_fmt = formatter_of_out_channel source_out in
      Log.report ~level:1 (fun fmt -> fprintf fmt ".. java code generation@,@?");
      Java_backend.translate_to_java source_fmt basename normalized_prog machine_code;*)
      end
    | "horn" ->
       begin
	let source_file = destname ^ ".smt2" in (* Could be changed *)
	let source_out = open_out source_file in
	let fmt = formatter_of_out_channel source_out in
	Log.report ~level:1 (fun fmt -> fprintf fmt ".. hornification@,");
        Horn_backend.translate fmt basename prog machine_code;
	(* Tracability file if option is activated *)
	if !Options.traces then (
	let traces_file = destname ^ ".traces.xml" in (* Could be changed *)
	let traces_out = open_out traces_file in
	let fmt = formatter_of_out_channel traces_out in
        Log.report ~level:1 (fun fmt -> fprintf fmt ".. tracing info@,");
	Horn_backend.traces_file fmt basename prog machine_code;
	)
      end
    | "lustre" ->
      begin
	let source_file = destname ^ ".lustrec.lus" in (* Could be changed *)
	let source_out = open_out source_file in
	let fmt = formatter_of_out_channel source_out in
	Printers.pp_prog fmt prog;
(*	Lustre_backend.translate fmt basename normalized_prog machine_code *)
	()
      end

    | _ -> assert false
  in
  begin
    Log.report ~level:1 (fun fmt -> fprintf fmt ".. done @ @]@.");
  (* We stop the process here *)
    exit 0
  end

let compile dirname basename extension =
  match extension with
  | ".lusi"  -> compile_header dirname basename extension
  | ".lus"   -> compile_source dirname basename extension
  | _        -> assert false

let anonymous filename =
  let ok_ext, ext = List.fold_left
    (fun (ok, ext) ext' ->
      if not ok && Filename.check_suffix filename ext' then
	true, ext'
      else
	ok, ext)
    (false, "") extensions in
  if ok_ext then
    let dirname = Filename.dirname filename in
    let basename = Filename.chop_suffix (Filename.basename filename) ext in
    compile dirname basename ext
  else
    raise (Arg.Bad ("Can only compile *.lusi, *.lus or *.ec files"))

let _ =
  Corelang.add_internal_funs ();
  try
    Printexc.record_backtrace true;
    Arg.parse Options.options anonymous usage
  with
  | Parse.Syntax_err _ | Lexer_lustre.Error _
  | Types.Error (_,_) | Clocks.Error (_,_)
  | Corelang.Error _ (*| Task_set.Error _*)
  | Causality.Cycle _ -> exit 1
  | Sys_error msg -> (eprintf "Failure: %s@." msg)
  | exc -> (Utils.track_exception (); raise exc)

(* Local Variables: *)
(* compile-command:"make -C .." *)
(* End: *)
