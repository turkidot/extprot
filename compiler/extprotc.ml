
open Printf
open ExtList
open ExtString

module G = Gencode.Make(Gen_OCaml)
module PP = Gencode.Prettyprint

let (|>) x f = f x
let (@@) f x = f x

let file       = ref None
let output     = ref None
let generators = ref None
let width      = ref 100
let nolocs     = ref false

let arg_spec =
  Arg.align
    [
      "-o", Arg.String (fun f -> output := Some f), "FILE Set output file.";

      "-g", Arg.String (fun gs -> generators := Some (String.nsplit gs ",")),
        "LIST Generators to use (comma-separated).";

      "-nolocs", Arg.Set nolocs,
        " Do not indicate precise locations by default in deserialization exceptions.";

      "-w", Arg.Set_int width,
        sprintf "N Set width to N characters in generated code (default: %d)." !width;
    ]

let usage_msg =
  sprintf
    "\nUsage: extprotc [OPTIONS] <file>\n\n\
     Known generators:\n\n\
     %s\n\n\
     Options:\n" @@
    String.concat "\n" @@
      List.map
        (fun (lang, gens) -> sprintf "  %s: %s" lang @@ String.join ", " gens)
        [
          "OCaml", G.generators;
        ]

let print_header ?(sub = '=') fmt =
  kprintf
    (fun s ->
       Format.fprintf Format.err_formatter "%s@.%s@." s
         (String.make (String.length s) sub))
    fmt

let print fmt = Format.fprintf Format.err_formatter fmt

let () =
  Arg.parse arg_spec (fun fname -> file := Some fname) usage_msg;
  match !file with
  | None -> ()
  | Some file ->
       let output = match !output with
           None -> Filename.chop_extension file ^ ".ml"
         | Some f -> f in

       if output = file then begin
         print "extprotc: refusing to overwrite %S@." file;
         exit 2
       end;

       let och      = open_out output in
       let entries  = Parser.print_synerr Parser.parse_file file in
       let decls    = List.filter_map (function (Ptypes.Decl decl, _) -> Some decl | _ -> None) entries in
       let bindings = Gencode.collect_bindings decls in
       let local    = List.filter_map (function (entry,Ptypes.Local) -> Some entry | (_,Ptypes.Extern) -> None) entries in

       let global_opts =
         if !nolocs then ["locs", "false"]
         else []
       in
         begin
           match Ptypes.check_declarations decls with
             | [] ->
                 G.generate_code
                   ~global_opts
                   ~width:!width ?generators:!generators bindings local |> output_string och
             | errors ->
                 print "Found %d errors:@." (List.length errors);
                 Ptypes.pp_errors Format.err_formatter errors;
                 print "@.@]";
                 exit 1
         end
