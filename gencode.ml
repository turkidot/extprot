
open Ptypes
open ExtList
open Printf

type tag = int

type low_level =
    Vint of vint_meaning
  | Bitstring32
  | Bitstring64 of b64_meaning
  | Bytes
  | Sum of constructor list * (constructor * low_level list) list
  | Tuple of low_level list
  | Htuple of htuple_meaning * low_level
  | Message of string

and constructor = {
  const_tag : tag;
  const_name : string;
  const_type : string;
}

and low_level_record =
  | Record_single of (string * bool * low_level) list
  | Record_sum of (string * (string * bool * low_level) list) list

and vint_meaning =
    Bool
  | Positive_int
  | Int

and b64_meaning =
    Long
  | Float

and htuple_meaning =
    List
  | Array

type reduced_type_expr = [
    reduced_type_expr base_type_expr_core
  | `Sum of reduced_type_expr sum_data_type
  | `Message of string
]

type poly_type_expr_core = [
    poly_type_expr_core base_type_expr_core
  | `Type of string * poly_type_expr_core list (* polymorphic sum type name, type args *)
  | `Type_arg of string
]

type poly_type_expr = [
  poly_type_expr_core
  | `Sum of poly_type_expr_core sum_data_type
]

let reduced_type_expr e = (e :> reduced_type_expr)

type bindings = declaration SMap.t

let failwithfmt fmt = kprintf (fun s -> if true then failwith s) fmt

let update_bindings bindings params args =
  List.fold_right2 SMap.add params args bindings

let rec beta_reduce_aux f self (bindings : bindings) = function
  | #base_type_expr_simple as x -> x
  | `Tuple l -> `Tuple (List.map (self bindings) (l :> type_expr list))
  | `List t -> `List (self bindings (type_expr t))
  | `Array t -> `Array (self bindings (type_expr t))
  | (`Sum _ | `App _ | `Type_param _) as x -> f bindings x

let beta_reduce_sum self bindings s =
  let non_const =
    List.map
      (fun (const, tys) ->
         (const, List.map (self bindings) (tys :> type_expr list)))
      s.non_constant
  in `Sum { s with non_constant = non_const }

let rec beta_reduce_texpr bindings texpr : reduced_type_expr =
  let aux bindings x : reduced_type_expr = match x with
      `Sum s -> beta_reduce_sum beta_reduce_texpr bindings s
    | `Type_param p ->
        let name = string_of_type_param p in begin match smap_find name bindings with
            Some (Message_decl (name, _)) -> `Message name
          | Some (Type_decl (name, [], exp)) -> beta_reduce_texpr bindings exp
          | Some (Type_decl (_, _, _)) ->
              failwithfmt "beta_reduce_texpr: wrong arity for higher-order type %S" name;
              assert false
          | _ -> failwithfmt "beta_reduce_texpr: unbound type variable %S" name;
                 assert false
        end

    | `App (name, args) -> match smap_find name bindings with
          Some (Message_decl _) -> `Message name
        | Some (Type_decl (name, params, exp)) ->
            let bindings =
              update_bindings bindings (List.map string_of_type_param params)
                (List.map (fun ty -> Type_decl ("<bogus>", [], type_expr ty)) args)
            in beta_reduce_texpr bindings exp
        | None -> failwithfmt "beta_reduce_texpr: unbound type variable %S" name;
                  assert false
  in beta_reduce_aux aux beta_reduce_texpr bindings texpr

let rec reduce_to_poly_texpr_core bindings (texpr : type_expr) : poly_type_expr_core =
  let self = reduce_to_poly_texpr_core in

  let aux bindings x : poly_type_expr_core = match x with
      `Sum _ ->
        (* `Type (s.type_name, []) in *)
        (* there shouldn't be any of these left *)
        assert false
    | `Type_param p -> `Type_arg (type_param_name p)
    | `App (name, args) -> match smap_find name bindings with
          Some (Message_decl _) -> `Type (name, [])
        | Some (Type_decl (name, params, `Sum _)) ->
            `Type (name, List.map (self bindings) (args :> type_expr list))
        | Some (Type_decl (name, params, exp)) ->
            let bindings =
              update_bindings bindings (List.map string_of_type_param params)
                (List.map (fun ty -> Type_decl ("<bogus>", [], type_expr ty)) args)
            in self bindings exp
        | None -> `Type_arg name

  in beta_reduce_aux aux self bindings texpr

let poly_beta_reduce_texpr bindings : type_expr -> poly_type_expr = function
  (* must expand top-level `Sum!
    * otherwise the expr for type foo = A | B becomes `Type foo *)
    `Sum s -> beta_reduce_sum reduce_to_poly_texpr_core bindings s
  | s -> (reduce_to_poly_texpr_core bindings s :> poly_type_expr)


let low_level_msg_def bindings (msg : message_expr) =

  let rec low_level_of_rtexp : [reduced_type_expr] -> low_level = function
      `Bool -> Vint Bool
    | `Byte -> Vint Positive_int
    | `Int true -> Vint Positive_int
    | `Int false -> Vint Int
    | `Long_int -> Bitstring64 Long
    | `Float -> Bitstring64 Float
    | `String -> Bytes
    | `Tuple l -> Tuple (List.map low_level_of_rtexp (l :> reduced_type_expr list))
    | `List ty -> Htuple (List, low_level_of_rtexp (reduced_type_expr ty))
    | `Array ty -> Htuple (Array, low_level_of_rtexp (reduced_type_expr ty))
    | `Message s -> Message s
    | `Sum sum ->
        let constant =
          List.mapi
            (fun i s -> { const_tag = i; const_name = s; const_type = sum.type_name })
            sum.constant in
        let non_constant =
          List.mapi
            (fun i (const, tys) ->
               ({ const_tag = i; const_name = const; const_type = sum.type_name},
                List.map low_level_of_rtexp tys))
            sum.non_constant
        in Sum (constant, non_constant) in

  let rec low_level_of_mexpr : message_expr -> low_level_record =
    let low_level_field (const, mutabl, ty) =
      (const, mutabl, low_level_of_rtexp (beta_reduce_texpr bindings (type_expr ty)))

    in function
      `Sum cases  ->
        Record_sum
          (List.map
             (fun (const, `Record fields) -> (const, List.map low_level_field fields))
             cases)
    | `Record fields -> Record_single (List.map low_level_field fields)

  in low_level_of_mexpr msg

let collect_bindings =
  List.fold_left (fun m decl -> SMap.add (declaration_name decl) decl m) SMap.empty

module type GENCODE =
sig
  type container

  val generate_container : bindings -> declaration -> container option
  val add_message_reader : bindings -> string -> message_expr -> container -> container
  val add_message_writer : bindings -> string -> message_expr -> container -> container
  val generate_code : container list -> string
end

let (|>) x f = f x

module Make(Gen : GENCODE) =
struct
  open Gen

  let generate_code (decls : declaration list) =
    let bindings = collect_bindings decls in
      List.filter_map
        (fun decl ->
           match generate_container bindings decl with
               None -> None
             | Some cont ->
                 match decl with
                     Type_decl _ -> Some cont
                   | Message_decl (name, expr) ->
                       Some (add_message_reader bindings name expr cont |>
                               add_message_writer bindings name expr))
        decls
    |> generate_code
end

module Prettyprint =
struct
  open Format
  let pp = fprintf
  let pp' fmt ppf = pp ppf fmt

  let list elt sep ppf =
    let rec loop = function
        [] -> ()
      | x::xs -> pp ppf sep; elt ppf x; loop xs
    in function
        [] -> ()
      | [x] -> elt ppf x
      | x::xs -> elt ppf x; loop xs

  let pp_base_expr_simple ppf : base_type_expr_simple -> unit = function
      `Bool -> pp ppf "Bool"
    | `Byte -> pp ppf "Byte"
    | `Int b -> pp ppf "Int %s" (string_of_bool b)
    | `Long_int -> pp ppf "Long_int"
    | `Float -> pp ppf "Float"
    | `String -> pp ppf "String"

  let pp_base_type_expr_core f ppf : 'a base_type_expr_core -> unit = function
      `Tuple l -> pp ppf "@[<1>(%a)@]" (list f " *@ ") l
    | `List t -> pp ppf "@[<1>[%a]@]" f t
    | `Array t -> pp ppf "@[<1>[|%a|]@]" f t
    | #base_type_expr_simple as x -> pp_base_expr_simple ppf x

  let rec pp_reduced_type_expr ppf : reduced_type_expr -> unit = function
      `Sum s ->
        pp ppf "@[<1>%a%a]"
          (list (pp' "%s") "@ | ")
          s.constant
          (fun ppf l -> match l with
               [] -> ()
             | l ->
                 let elt ppf (const, l) =
                   pp ppf "%s @[<1>(%a)@]"
                     const (list pp_reduced_type_expr "@ ") l
                 in pp ppf "@ | %a" (list elt "@ | %a") l)
          s.non_constant
    | `Message s -> pp ppf "msg:%S" s
    | #base_type_expr_core as x ->
        pp_base_type_expr_core pp_reduced_type_expr ppf x

end
