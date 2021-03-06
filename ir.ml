type value =
  | Constant of int
  | Fun of string list * string * string * expression
    (* Values used to implement await. *)
  | Await of string * string * string
      
and expression =
  | LetVal of string * value * expression
  | LetCont of string * string list * expression * expression
  | CallFun of string * string list * string * string
  | CallCont of string * string list
  | If of string * expression * expression

type function_declaration =
  | FunDecl of string * string list * string * string * expression

(* ==== Serializing to S-expressions ==== *)
open Sexp

let serialize_string_list lst =
  Slist (List.map (fun a -> Atom a) lst)

let rec serialize_value = function
  | Constant n -> Slist [Atom "Constant"; Atom (string_of_int n)]
  | Fun (parameters, return, throw, body) ->
    Slist [Atom "Fun"; serialize_string_list parameters; Atom return;
	   Atom throw; serialize_expression body]
  | Await (value, normal, error) ->
    Slist [Atom "Await"; Atom value; Atom normal; Atom error]

and serialize_expression = function
  | LetVal (name, rhs, body) ->
    Slist [Atom "LetVal"; Atom name; serialize_value rhs;
	   serialize_expression body]
  | LetCont (name, parameters, cont_body, body) ->
    Slist [Atom "LetCont"; Atom name; serialize_string_list parameters;
	   serialize_expression cont_body; serialize_expression body]
  | CallFun (name, arguments, return, throw) ->
    Slist [Atom "CallFun"; Atom name; serialize_string_list arguments;
	   Atom return; Atom throw]
  | CallCont (name, arguments) ->
    Slist [Atom "CallCont"; Atom name; serialize_string_list arguments]
  | If (condition, thn, els) ->
    Slist [Atom "If"; Atom condition; serialize_expression thn;
           serialize_expression els]

let serialize_function_declaration = function
  | FunDecl (name, parameters, return, throw, body) ->
    Slist [Atom "FunDecl"; Atom name; serialize_string_list parameters;
	   Atom return; Atom throw; serialize_expression body]

(* Write a list of IR function declarations as S-expressions. *)
let write_ir chan lst =
  write_sexp chan (Slist (List.map serialize_function_declaration lst))
