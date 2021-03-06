open Ctype

type value =
  | VInt   of int
  | VFloat of float
  | VStr   of int list

type expr =
  | ENil
  | EArith   of ctype * arith_bin   * expr * expr
  | EFArith  of ctype * arith_bin   * expr * expr
  | EPAdd    of ctype * expr * expr
  | EPDiff   of ctype * expr * expr
  | ERel     of ctype * rel_bin     * expr * expr
  | EURel    of ctype * rel_bin     * expr * expr
  | EFRel    of ctype * rel_bin     * expr * expr
  | EEq      of ctype * eq_bin      * expr * expr
  | EFEq     of ctype * eq_bin      * expr * expr
  | ELog     of ctype * logical_bin * expr * expr
  | EUnary   of ctype * unary * expr
  | EFUnary  of ctype * unary * expr
  | EPPost   of ctype * inc * expr
  | EConst   of ctype * value
  | EVar     of ctype * name
  | EComma   of ctype * expr * expr
  | EAssign  of ctype * arith_bin option * expr * expr
  | EFAssign of ctype * arith_bin option * expr * expr
  | ECall    of ctype * expr * (expr list)
  | EAddr    of ctype * expr
  | EPtr     of ctype * expr
  | ECond    of ctype * expr * expr * expr
  | EDot     of ctype * expr * name
  | ECast    of ctype * ctype * expr
  | EAsm     of ctype * (int list)
  | ESpace   of ctype

type decl =
  | Decl of linkage * ctype * name * (expr list)

type stmt =
  | SNil
  | SBlock of decl list * stmt list
  | SWhile of expr * stmt
  | SDoWhile of stmt * expr
  | SFor of (expr option) * (expr option) * (expr option) * stmt
  | SIfElse of expr * stmt * stmt
  | SReturn of expr option
  | SContinue
  | SBreak
  | SLabel of string * stmt
  | SGoto of string
  | SSwitch of expr * stmt
  | SCase of int
  | SDefault
  | SExpr of expr

type def =
  | DefFun of decl * (decl list) * stmt
  | DefVar of decl

let typeof = function
  | EArith  (t, _, _, _) -> t
  | EFArith (t, _, _, _) -> t
  | ERel    (t, _, _, _) -> t
  | EURel   (t, _, _, _) -> t
  | EFRel   (t, _, _, _) -> t
  | EPAdd   (t, _, _) -> t
  | EPDiff  (t, _, _) -> t
  | EEq     (t, _, _, _) -> t
  | EFEq    (t, _, _, _) -> t
  | ELog    (t, _, _, _) -> t
  | EUnary  (t, _, _) -> t
  | EFUnary (t, _, _) -> t
  | EPPost  (t, _, _) -> t
  | EConst  (t, _) -> t
  | EVar    (t, _) -> t
  | EComma  (t, _, _) -> t
  | EAssign (t, _, _, _) -> t
  | EFAssign(t, _, _, _) -> t
  | ECall   (t, _, _) -> t
  | EAddr   (t, _) -> t
  | EPtr    (t, _) -> t
  | ECond   (t, _, _, _) -> t
  | EDot    (t, _, _) -> t
  | ECast   (t, _, _) -> t
  | EAsm    (t, _) -> t
  | ENil -> failwith "typeof ENil"
  | ESpace _ -> failwith "typeof ESpace"
