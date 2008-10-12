
open Printf
open Ptypes
open Gencode
open Camlp4
open PreCast
open Ast

type container = {
  c_name : string;
  c_types : Ast.str_item option;
  c_code : Ast.str_item option;
}

let (|>) x f = f x

let foldl1 msg f g = function
    [] -> invalid_arg ("foldl1: empty list -- " ^ msg)
  | hd::tl -> List.fold_left g (f hd) tl

let foldr1 msg f g = function
    [] -> invalid_arg ("foldr1: empty list -- " ^ msg)
  | l -> match List.rev l with
        [] -> assert false
      | hd::tl -> List.fold_left (fun s x -> g x s) (f hd) tl

let generate_container bindings =
  let _loc = Loc.mk "gen_OCaml" in

  let typedecl name ?(params = []) ctyp =
    Ast.TyDcl (_loc, name, params, ctyp, []) in

  let typedef name ?(params = []) ctyp =
      <:str_item< type $typedecl name ~params ctyp $ >> in

  let rec message_types msgname = function
      `Record l ->
        let ctyp (name, mutabl, texpr) =
          let ty = ctyp_of_texpr texpr in match mutabl with
              true -> <:ctyp< $lid:name$ : mutable $ty$ >>
            | false -> <:ctyp< $lid:name$ : $ty$ >> in
        let fields =
          foldl1 "message_types `Record" ctyp
            (fun ct field -> <:ctyp< $ct$; $ctyp field$ >>) l
        (* no quotations for type, wtf? *)
        (* in <:str_item< type $msgname$ = { $fields$ } >> *)
        in typedef msgname <:ctyp< { $fields$ } >>

   | `Sum l ->
       let tydef_of_msg_branch (const, mexpr) =
         message_types (msgname ^ "_" ^ const) (mexpr :> message_expr) in
       let record_types =
         foldl1 "message_types `Sum" tydef_of_msg_branch
           (fun s b -> <:str_item< $s$; $tydef_of_msg_branch b$ >>) l in

       let variant (const, _) =
         <:ctyp< $uid:const$ of ($lid: msgname ^ "_" ^ const $) >> in
       let consts = foldl1 "message_types `Sum" variant
                      (fun vars c -> <:ctyp< $vars$ | $variant c$ >>) l

       in <:str_item< $record_types$; $typedef msgname <:ctyp< [$consts$] >>$ >>

  and ctyp_of_texpr expr =
    type_expr expr |> reduce_to_poly_texpr_core bindings |> ctyp_of_poly_texpr_core

  and ctyp_of_poly_texpr_core = function
      `Bool -> <:ctyp< bool >>
    | `Byte -> <:ctyp< char >>
    | `Int _ -> <:ctyp< int >>
    | `Long_int -> <:ctyp< Int64.t >>
    | `Float -> <:ctyp< float >>
    | `String -> <:ctyp< string >>
    | `List ty -> <:ctyp< list $ctyp_of_poly_texpr_core ty$ >>
    | `Array ty -> <:ctyp< array $ctyp_of_poly_texpr_core ty$ >>
    | `Tuple l ->
        foldr1 "ctyp_of_poly_texpr_core `Tuple" ctyp_of_poly_texpr_core
          (fun ptexpr tup -> <:ctyp< ( $ ctyp_of_poly_texpr_core ptexpr $ * $tup$ ) >>)
          l
    | `Type (name, args) ->
        let t = List.fold_left (* apply *)
                  (fun ty ptexpr -> <:ctyp< $ty$ $ctyp_of_poly_texpr_core ptexpr$ >>)
                  <:ctyp< $lid:name$ >>
                  args
        in (try <:ctyp< $id:Ast.ident_of_ctyp t$ >> with Invalid_argument _ -> t)
    | `Type_arg n -> <:ctyp< '$n$ >>

  in function
      Message_decl (msgname, mexpr) ->
        Some {
          c_name = msgname;
          c_types = Some (message_types msgname mexpr);
          c_code = None;
        }
    | Type_decl (name, params, texpr) ->
        let ty = match poly_beta_reduce_texpr bindings texpr with
            `Sum s -> begin
              let ty_of_const_texprs (const, ptexprs) =
                let ty = ctyp_of_poly_texpr_core (`Tuple ptexprs) in
                  <:ctyp< $uid:const$ of $ty$ >>

              in match s.constant with
                  [] -> foldl1 "generate_container Type_decl `Sum"
                          ty_of_const_texprs
                          (fun ctyp c -> <:ctyp< $ctyp$ | $ty_of_const_texprs c$ >>)
                          s.non_constant
                | _ ->
                    let const =
                      foldl1 "generate_container `Sum"
                        (fun tyn -> <:ctyp< $uid:tyn$ >>)
                        (fun ctyp tyn -> <:ctyp< $ctyp$ | $uid:tyn$ >>)
                        s.constant

                    in List.fold_left
                         (fun ctyp c -> <:ctyp< $ctyp$ | $ty_of_const_texprs c$ >>)
                         const s.non_constant
            end
          | #poly_type_expr_core ->
              reduce_to_poly_texpr_core bindings texpr |> ctyp_of_poly_texpr_core in
        let params =
          List.map (fun n -> <:ctyp< '$lid:type_param_name n$ >>) params
        in
          Some {
            c_name = name;
            c_types = Some <:str_item< type $typedecl name ~params ty$ >>;
            c_code = None;
          }

let loc = Camlp4.PreCast.Loc.mk

let maybe_str_item =
  let _loc = loc "<generated code>" in
    Option.default <:str_item< >>

module PrOCaml =Camlp4.Printers.OCaml.Make(Camlp4.PreCast.Syntax)

let string_of_ast f ast =
  let b = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer b in
  let o = new PrOCaml.printer () in
    Format.fprintf fmt "@[<v0>%a@]@." (f o) ast;
    Buffer.contents b

let generate_code containers =
  let _loc = loc "<generated code>" in
  let container_of_str_item c =
    <:str_item<
       module $String.capitalize c.c_name$ = struct
         $maybe_str_item c.c_types$;
         $maybe_str_item c.c_code$
       end >>
  in string_of_ast (fun o -> o#implem)
       (List.fold_left
          (fun s c -> <:str_item< $s$; $container_of_str_item c$ >>)
          <:str_item< >>
          containers)

  (* val add_message_reader : bindings -> string -> message_expr -> container -> container *)
  (* val add_message_writer : bindings -> string -> message_expr -> container -> container *)

let list_mapi f l =
  let i = ref (-1) in
    List.map (fun x -> incr i; f !i x) l

let rec field_match_cases msgname constr_name ?default name =
  let _loc = loc "<generated code @ field_match_cases>" in
  let default = match default with
      Some e -> e
    | None -> <:expr< Extprot.Codec.bad_format
                        $str:msgname$ $str:constr_name$ $str:name$ >> in

  let rec read = function
      Vint Bool ->
        <:expr<
          match Extprot.Codec.read_vint s with [
              0 -> False
            | _ -> True
          ]
        >>
    | Vint Int -> <:expr< Extprot.Codec.read_rel_vint s >>
    | Vint Positive_int -> <:expr< Extprot.Codec.read_vint s>>
    | Bitstring32 -> <:expr< Extprot.Codec.read_i32 s >>
    | Bitstring64 Long -> <:expr< Extprot.Codec.read_i64 s >>
    | Bitstring64 Float -> <:expr< Extprot.Codec.read_float s >>
    | Bytes -> <:expr< Extprot.Codec.read_string s >>
    | Tuple lltys ->
        (* TODO: handle missing elms *)
        let vars = Array.to_list (Array.init (List.length lltys) (sprintf "v%d")) in
        let tup = exCom_of_list (List.rev_map (fun v -> <:expr< $lid:v$ >>) vars) in
        let v, _ =
          List.fold_right
            (fun llty (e, vs) -> match vs with
                 v::vs -> (<:expr< let $lid:v$ = $read llty$ in $e$ >>, vs)
               | [] -> assert false)
            lltys
            (tup, vars)
        in v
    | Sum (constant, non_constant) ->
        let constant_match_cases =
          List.map
            (fun c ->
               <:match_case<
                 $int:string_of_int c.const_tag$ ->
                   $uid:String.capitalize c.const_type$.$lid:c.const_name$
               >>)
            constant
          @ [ <:match_case<
                _ -> Extprot.Codec.bad_format
                       $str:msgname$ $str:constr_name$ $str:name$ >> ] in
        let nonconstant_match_cases =
          let mc (c, lltys) =
            <:match_case<
               $int:string_of_int c.const_tag$ ->
                 $uid:String.capitalize c.const_type$.$lid:c.const_name$ $read (Tuple lltys)$ >>
          in List.map mc non_constant
        in
          <:expr< let t = Extprot.Codec.read_vint s in
            match Extprot.Codec.ll_type t with [
                Extprot.Codec.Vint ->
                  match Extprot.Codec.ll_tag t with [ $Ast.mcOr_of_list constant_match_cases$ ]
              | Extprot.Codec.Tuple ->
                  match Extprot.Codec.ll_tag t with [ $Ast.mcOr_of_list nonconstant_match_cases$ ]
              | _ -> Extprot.Codec.unknown_tag
                       $str:msgname$ $str:constr_name$ $str:name$ tag
            ]
          >>
    | Message name ->
        <:expr< $uid:String.capitalize name$.$lid:"read_" ^ name$ s >>
    | Htuple (kind, llty) -> begin match kind with
          List ->
            <:expr<
              let len = Extprot.Codec.read_vint s in
              let nelms = Extprot.Codec.read_vint s in
              let rec loop acc = fun [
                  0 -> List.rev acc
                | n -> let v = $read llty$ in loop [v :: acc] (n - 1)
              ] in loop [] nelms
            >>
       |  Array ->
           <:expr<
              let len = Extprot.Codec.read_vint s in
              let nelms = Extprot.Codec.read_vint s in match nelms with [
                  0 -> [||]
                | n ->
                    let elm = $read llty$ in
                    let a = Array.make nelms elm in
                      for i = 1 to nelms - 1 do
                        a.(i) := $read llty$
                      done
              ]
            >>
      end in

  let expected_type = function
      Vint _ -> <:expr< Extprot.Codec.Vint >>
    | Bitstring32 -> <:expr< Extprot.Codec.Bitstring32 >>
    | Bitstring64 _ -> <:expr< Extprot.Codec.Bitstring64 >>
    | Bytes -> <:expr< Extprot.Codec.Bytes >>
    | Tuple _ -> <:expr< Extprot.Codec.Tuple >>
    | Htuple _ -> <:expr< Extprot.Codec.HTuple >>
    | Message _ -> <:expr< Extprot.Codec.Tuple >>
    | Sum _ -> assert false

  in function

    Vint _ | Bitstring32 | Bitstring64 _ | Bytes as ty ->
      <:match_case< 0 ->
         if Extprot.ll_type t = $expected_type ty$ then
           $read ty$
         else $default$
      >>
  | Tuple _ | Sum _ | Message _ as ty ->
      <:match_case< tag -> try do { Extprot.Codec.pushback s; $read ty$ } with [_ -> $default$] >>
  | Htuple _ -> failwith "TODO"

let record_case msgname ?constr tag fields =
  let _loc = Loc.mk "<generated code @ record_case>" in
  let constr_name = Option.default "<default>" constr in

  let read_field fieldno (name, mutabl, llty) ?default expr =
    let rescue_match_case = match default with
        None ->
          <:match_case<
            Extprot.Bad_format _ | Extprot.Unknown_tag _ as e -> raise e
          >>
      | Some expr ->
          <:match_case< Extprot.Bad_format _ | Extprot.Unknown_tag _ -> $expr$ >> in
    let default_value = match default with
        Some expr -> expr
      | None ->
          <:expr< Extprot.Codec.missing_field
                    $str:msgname$ $str:constr_name$ $str:name$ >>
    in
      <:expr<
         let $lid:name$ =
           if nelms >= $int:string_of_int fieldno$ then
             try
               let t = ExtProt.Codec.read_vint s in
                 match Extprot.Codec.ll_tag t with
                     [
                       $field_match_cases msgname constr_name name llty$
                     | n -> Extprot.Codec.unknown_tag
                              $str:msgname$ $str:constr_name$ $str:name$ n
                     ]
             with [$rescue_match_case$]
           else
               $default_value$
         in $expr$
      >> in

  let field_assigns =
    List.map
      (fun (name, _, _) -> <:rec_binding< $lid:name$ = $lid:name$ >>)
      fields in
  let e =
    List.fold_right
      (fun (i, fieldinfo) e -> read_field i fieldinfo e)
      (list_mapi (fun i x -> (i, x)) fields)
      <:expr< { $Ast.rbSem_of_list field_assigns$ } >>
  in
    <:match_case<
      $int:tag$ ->
        let len = Extprot.Codec.read_vint s in
        let eom = Extprot.Codec.marker s len in
        let nelms = Extprot.Codec.read_vint s in
          $e$
          >>
(* let add_message_reader bindings msgname mexpr c = *)
  (* <:match_case< $int:tag$ -> $record_expr$ >> *)


  (* let llexpr = Gencode.low_level_msg_def bindings mexpr in *)