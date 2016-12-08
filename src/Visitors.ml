open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience
open Ppx_deriving
open VisitorsGeneration

(* -------------------------------------------------------------------------- *)

(* General infrastructure. *)

let plugin =
  "visitors"

(* No options are supported. *)

let parse_options options =
  options |> List.iter (fun (name, expr) ->
    match name with
    | _ ->
       raise_errorf
         ~loc:expr.pexp_loc
         "%s does not support option %s"
         plugin
         name
  )

(* -------------------------------------------------------------------------- *)

(* Helper functions for abstract syntax tree analysis. *)

let ld_to_lty (ld : label_declaration) : label * core_type =
  (* Extract the label and type. *)
  let { pld_name = { txt = label; _ }; pld_type = ty; _ } = ld in
  label, ty

(* [defined decls] extracts the list of types that are declared by the type
   declarations [decls]. *)

let defined (decls : type_declaration list) : string list =
  List.map (fun decl -> decl.ptype_name.txt) decls

(* -------------------------------------------------------------------------- *)

(* Public naming conventions. *)

(* The name of the visitor base class. *)

let visitor =
  "visitor"

(* The names of the subclasses [iter] and [map]. *)

let iter =
  "iter"

let map =
  "map"

(* The name of the visitor method associated with a type constructor [tycon]. *)

let visitor_method (tycon : string) : string =
  tycon

let visitor_method (tycon : Longident.t) : string =
  match tycon with
  | Lident tycon
  | Ldot (_, tycon) ->
      visitor_method tycon
  | Lapply _ ->
      assert false (* should not happen...? *)

(* The name of the descending method associated with a data constructor [datacon]. *)

let datacon_visitor (datacon : string) : string =
  "match_" ^ datacon

(* The name of the constructor method associated with a data constructor [datacon]. *)

let datacon_constructor (datacon : string) : string =
  "build_" ^ datacon

(* -------------------------------------------------------------------------- *)

(* Private naming conventions. *)

(* The variable [self] refers to the visitor object we are constructing.
   The type variable [ty_self] denotes its type. *)

let self =
  "self"

let ty_self =
  Typ.var "self"

let pself =
  Pat.constraint_ (pvar self) ty_self

(* [call m es] produces a self-call to the method [m] with arguments [es]. *)

let call (m : string) (es : expression list) : expression =
  app (Exp.send (evar self) m) es

(* The variable [env] refers to the environment that is carried down into
   recursive calls. The type variable [ty_env] denotes its type. *)

let env =
  "env"

let ty_env : core_type =
  Typ.var "env"

let penv : pattern =
  Pat.constraint_ (pvar env) ty_env

(* -------------------------------------------------------------------------- *)

(* Per-run global state. *)

module Run (Current : sig val decls : type_declaration list end) = struct

(* As we generate several classes at the same time, we maintain, for each
   generated class, a list of methods that we generate as we go. *)

module S : sig

  val generate: string -> class_field -> unit
  val dump: string -> class_field list

end = struct

  module StringMap =
    Map.Make(String)

  let store : class_field list StringMap.t ref =
    ref StringMap.empty

  let get (c : string) : class_field list =
    try StringMap.find c !store with Not_found -> []

  let generate (c : string) (cf : class_field) =
    store := StringMap.add c (cf :: get c) !store

  let dump (c : string) =
    List.rev (get c)

end

(* [nonlocal] records the set of nonlocal type constructors that have been
   encountered as we go. *)

module StringSet =
  Set.Make(String)

let nonlocal =
  ref StringSet.empty

let insert_nonlocal (s : string) =
  nonlocal := StringSet.add s !nonlocal

(* [is_local tycon] tests whether the type constructor [tycon] is local,
   that is, whether it is declared by the current set of type declarations.
   At the same time, if [tycon] is found to be non-local, then it is added
   (in an unqualified form) to the set [nonlocal]. *)

let is_local (tycon : Longident.t) : bool =
  match tycon with
  | Lident s ->
      let is_local = List.mem s (defined Current.decls) in
      if not is_local then insert_nonlocal s;
      is_local
  | Ldot (_, s) ->
      insert_nonlocal s;
      false
  | Lapply _ ->
      false (* should not happen? *)

(* Suppose [e] is an expression whose free variables are [xs]. [hook m xs e]
   produces a call of the form [self#m xs], and (as a side effect) defines an
   auxiliary method [method m xs = e]. The default behavior of this expression
   is the behavior of [e], but we offer the user a hook, named [m], which
   allows this default to be overridden. *)

let hook (m : string) (xs : string list) (e : expression) : expression =
  (* Generate an auxiliary method. We note that its parameters [xs] don't
     need a type annotation: because this method has a call site, its type
     can be inferred. *)
  S.generate visitor (
    mkconcretemethod m (lambdas xs e)
  );
  (* Generate a method call. *)
  call m (evars xs)

(* [postprocess m es] evaluates the expressions [es] in turn, binding their
   results to some variables [xs], then makes a self call to the method [m],
   passing the variables [xs] as arguments. This is used in the ascending
   phase of the visitor: the variables [xs] represent the results of the
   recursive calls and the method call [self#m xs] is in charge of
   reconstructing a tree node (or some other result). *)

(* TEMPORARY needs cleaning up *)

let postprocess reconstruct (m : string) (es : expression list) : expression =
  (* Generate a declaration of [m] as an auxiliary virtual method. We note
     that it does not need a type annotation: because we have used the trick
     of parameterizing the class over its ['self] type, no annotations at all
     are needed. *)
  S.generate visitor (
    mkvirtualmethod m
  );
  (* This virtual method is defined in the subclass [iter] to always return
     unit. *)
  let wildcards = List.map (fun _ -> Pat.any()) es in
  S.generate iter (
    mkconcretemethod m (plambdas wildcards (unit()))
  );
  (* It is defined in the subclass [map] to always reconstruct a tree node. *)
  (* Generate a method call. *)
  mlet es (fun xs ->
    S.generate map (mkconcretemethod m (lambdas xs (reconstruct xs)));
    call m (evars xs)
  )

(* -------------------------------------------------------------------------- *)

(* [core_type ty] builds a small expression, typically a variable or a function
   call, which represents the derived function associated with the type [ty]. *)

let rec core_type (ty : core_type) : expression =
  match ty with

  (* A type constructor [tycon] applied to type parameters [tys]. *)
  | { ptyp_desc = Ptyp_constr ({ txt = tycon; _ }, tys); _ } ->
      let tycon : Longident.t = tycon
      and tys : core_type list = tys in
      (* Check if this is a local type constructor. If not, generate a
         virtual method for it. *)
      if not (is_local tycon) then
        S.generate visitor (
          mkvirtualmethod (visitor_method tycon)
        );
      (* Construct the name of the [visit] method associated with [tycon].
         Apply it to the derived functions associated with [tys] and to
         the environment [env]. *)
      call (visitor_method tycon) (List.map core_type tys @ [evar env])

  (* A tuple type. *)
  | { ptyp_desc = Ptyp_tuple tys; _ } ->
      (* Construct a function. In the case of tuples, we do not call an
         ascending auxiliary method, as we would need one method name
         per tuple type, and that would be messy. Instead, we make the
         most general choice of ascending computation, which is to rebuild
         a tuple on the way up. Happily, this is always well-typed. *)
      let xs, es = tuple_type tys in
      plambda (ptuple (pvars xs)) (tuple es)

  (* An unsupported construct. *)
  | { ptyp_loc; _ } ->
      raise_errorf
        ~loc:ptyp_loc
        "%s cannot be derived for %s"
        plugin
        (string_of_core_type ty)

and tuple_type (tys : core_type list) : string list * expression list =
  (* Set up a naming convention for the tuple components. Each component must
     receive a distinct name. The simplest convention is to use a fixed
     prefix followed with a numeric index. *)
  let x i = Printf.sprintf "c%d" i in
  (* Construct a pattern and expression. *)
  let xs = List.mapi (fun i _ty -> x i) tys in
  let es = List.mapi (fun i ty -> app (core_type ty) [evar (x i)]) tys in
  xs, es

(* -------------------------------------------------------------------------- *)

(* [constructor_declaration] turns a constructor declaration (as found in a
   declaration of a sum type) into a case, that is, a branch in a case
   analysis construct. *)

let constructor_declaration (cd : constructor_declaration) : case =
  (* Extract the data constructor name and arguments. *)
  let { pcd_name = { txt = datacon; _ }; pcd_args; _ } = cd in
  match pcd_args with

  (* A traditional constructor, whose arguments are anonymous. *)
  | Pcstr_tuple tys ->
      let xs, es = tuple_type tys in
      let reconstruct (xs : string list) : expression = constr datacon (evars xs) in
      Exp.case
        (pconstr datacon (pvars xs))
        (hook (datacon_visitor datacon) (env :: xs) (postprocess reconstruct (datacon_constructor datacon) es))

  (* An ``inline record'' constructor, whose arguments are named. (As of OCaml 4.03.) *)
  | Pcstr_record lds ->
      let ltys = List.map ld_to_lty lds in
      (* Set up a naming convention for the fields. The simplest convention
         is to use a fixed prefix followed with the field name. *)
      let x label = Printf.sprintf "f%s" label in
      (* Construct the pattern and expression. *)
      let lps = List.map (fun (label, _ty) -> label,              pvar (x label)) ltys
      and es  = List.map (fun (label,  ty) -> app (core_type ty) [evar (x label)]) ltys in
      let reconstruct (xs : string list) : expression =
        assert (List.length xs = List.length ltys);
        let lxs = List.map2 (fun (label, _ty) x -> (label, evar x)) ltys xs in
        constrrec datacon lxs
      in
      Exp.case (pconstrrec datacon lps) (postprocess reconstruct (datacon_constructor datacon) es)

(* -------------------------------------------------------------------------- *)

(* [type_decl_rhs decl] produces the right-hand side of the value binding
   associated with the type declaration [decl]. *)

let type_decl_rhs (decl : type_declaration) : expression =
  match decl.ptype_kind, decl.ptype_manifest with

  (* A type abbreviation. *)
  | Ptype_abstract, Some ty ->
      core_type ty

  (* A record type. *)
  | Ptype_record (lds : label_declaration list), _ ->
      let ltys = List.map ld_to_lty lds in
      (* Set up a naming convention for the record itself. Any name would do,
         but we choose to use the name of the type that is being declared. *)
      let x = decl.ptype_name.txt in
      (* Generate one function call for each field. *)
      let es : expression list = List.map (fun (label, ty) ->
        app (core_type ty) [ Exp.field (evar x) (mknoloc (Lident label)) ]
      ) ltys in
      (* Construct a sequence of these calls, and place it in a function body. *)
      lambda x (sequence es)

  (* A sum type. *)
  | Ptype_variant (cds : constructor_declaration list), _ ->
      (* Generate one case per constructor, and place them in a function
         body, whose formal parameter is anonymous. *)
      Exp.function_ (List.map constructor_declaration cds)

  (* An unsupported construct. *)
  | _ ->
      raise_errorf
        ~loc:decl.ptype_loc
        "%s cannot be derived for this sort of type"
        plugin

(* -------------------------------------------------------------------------- *)

(* [type_decl decl] produces a class field (e.g., a method) associated with
   the type declaration [decl]. *)

let type_decl (decl : type_declaration) =
  (* Produce a single method definition, whose name is based on this type
     declaration. *)
  S.generate visitor (
    mkconcretemethod
      (visitor_method (Lident decl.ptype_name.txt))
      (plambda penv (type_decl_rhs decl))
  )

end

(* -------------------------------------------------------------------------- *)

(* [type_decls decls] produces structure items (that is, toplevel definitions)
   associated with the type declarations [decls]. *)

let type_decls ~options ~path:_ (decls : type_declaration list) : structure =
  parse_options options;
  (* Analyze the type definitions. *)
  let module R = Run(struct let decls = decls end) in
  R.S.generate iter (Cf.inherit_ Fresh (Cl.constr (mknoloc (Lident visitor)) [ ty_self; ty_env ]) None);
  R.S.generate map (Cf.inherit_ Fresh (Cl.constr (mknoloc (Lident visitor)) [ ty_self; ty_env ]) None);
  List.iter R.type_decl decls;
  (* Produce class definitions. Our classes are parameterized over the type
     variable ['env]. They are also parameterized over the type variable
     ['self], with a constraint that this is the type of [self]. This trick
     allows us to omit the declaration of the types of the virtual methods,
     even if these types include type variables. *)
  let params = [
    ty_self, Invariant;
    ty_env, Contravariant
  ] in
  [
    Str.class_ [ mkclass params visitor pself (R.S.dump visitor) ];
    Str.class_ [ mkclass params iter pself (R.S.dump iter) ];
    Str.class_ [ mkclass params map pself (R.S.dump map) ];
  ]

(* -------------------------------------------------------------------------- *)

(* We do not allow deriving any code on the fly, outside of a type declaration.
   Indeed, that would not make any sense: we need to generate a class and have
   a [self] parameter. *)

let no_core_type ty =
  raise_errorf
    ~loc:ty.ptyp_loc
    "%s cannot be used on the fly"
    plugin

(* -------------------------------------------------------------------------- *)

(* Register our plugin with [ppx_deriving]. *)

let () =
  register (
      create
        plugin
        ~core_type:no_core_type
        ~type_decl_str:type_decls
        ()
    )
