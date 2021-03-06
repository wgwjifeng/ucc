open Ctype
open Typed_syntax
open Printf
open Util

type storageplace =
  | Reg of int
  | Mem of int * int (*memory*)
  | Global of string * int

let register_list = Array.init 25 succ |> Array.to_list
let free_reg_stack = ref register_list
let buffer_ref : string list ref = ref []
let env_ref : (string * (ctype * storageplace)) list ref = ref []
let fun_name_ref = ref ""
let sp_offset_ref = ref 0
let static_locals_ref = ref []
let continue_flg_ref = ref false
let break_flg_ref = ref false
let is_leaf_function = ref true

(* label management *)
let created_label_num = ref 0
let con_stack : int list ref = ref []
let brk_stack : int list ref = ref []
let switch_counter = ref (-1)
let switch_stack = ref []
let switch_cases = ref []
let switch_defaults = ref []

let emit fmt =
  ksprintf (fun s -> push buffer_ref ("  "^s^"\n")) fmt
let emit_raw fmt =
  ksprintf (fun s -> push buffer_ref s) fmt
let emit_label num =
  push buffer_ref (sprintf "L%d:\n" num)

let raise_error fmt =
  ksprintf (fun s ->
    fprintf stderr "EmitError: %s (%s)\n" s !fun_name_ref;
    exit 1
  ) fmt

let insert_epilogue () =
  if !buffer_ref = [] || peek buffer_ref <> "  ret\n" then begin
    emit "mov r1, 0";
    emit "leave";
    emit "ret"
  end

let insert_halt () =
  let trap s = if s = "  ret\n" then "  halt\n" else s in
  buffer_ref := List.map trap !buffer_ref

let flush_buffer oc =
  let go s =
     if !is_leaf_function && String.slice s 2 7 = "enter" then
      let sz = String.slice s 8 (-1) in
      if not (sz = "" || sz = "0") then
        fprintf oc "  sub rsp, rsp, %s\n" sz;
    else if not (!is_leaf_function && String.slice s 2 7 = "leave") then
      fprintf oc "%s" s in
  List.iter go (List.rev !buffer_ref);
  if !buffer_ref <> [] then fprintf oc "\n";
  buffer_ref := []

let reg_alloc () =
  match !free_reg_stack with
  | [] ->
     raise_error "register starvation!!"
  | x::xs ->
     free_reg_stack := xs;
     x
let reg_use i =
  if List.mem i !free_reg_stack then
    free_reg_stack := List.filter (fun x->x!=i) !free_reg_stack
  else
    raise_error "Register r%d is not free!!" i

let reg_free i =
  if List.mem i !free_reg_stack then
    raise_error "Register r%d is already free!!" i
  else
    free_reg_stack := i::!free_reg_stack

let reg_free_all () =
  free_reg_stack := register_list

let get_used_reg () =
  List.filter
    (fun x -> (List.mem x !free_reg_stack) = false)
    register_list

let label_create () =
  created_label_num := !created_label_num + 1;
  !created_label_num

let escape_label s =
  sprintf "L_label_%s_%s" !fun_name_ref s

let escape_case i =
  let c = if i < 0 then "m" else "" in
  sprintf "L_case_%s_%d_%s%d" !fun_name_ref (peek switch_stack) c (abs i)

let escape_default () =
  sprintf "L_default_%s_%d" !fun_name_ref (peek switch_stack)

let resolve_var name =
  try
    List.assoc name !env_ref
  with
  | Not_found -> raise_error "not found %s" name

let sizeof_decl = function
  | Decl (NoLink,TFun _,_,_)
  | Decl (Extern,_,_,_)
  | Decl (Static,_,_,_) ->
     0
  | Decl (NoLink,ty,_,_) ->
    sizeof ty

let rec sizeof_block = function
  | SBlock (d, s) ->
     let s1 = aligned TInt (sum_of (List.map sizeof_decl d)) in
     let s2 = max_of (List.map sizeof_block s) in
     s1 + s2
  | SWhile (_, s)
  | SDoWhile (s, _)
  | SFor (_, _, _, s)
  | SLabel (_, s)
  | SSwitch (_, s) ->
     sizeof_block s
  | SIfElse (_, s, t) ->
     max (sizeof_block s) (sizeof_block t)
  | _ ->
     0

let push_args args = (* add args in env *)
  let rec go i = function
    | [] -> ()
    | (Decl (_, ty, name, _))::xs ->
       let sz = if ty = TVoid then 0 else max 4 (sizeof ty) in
       env_ref := (name, (ty, Mem (31, i))) :: !env_ref;
       go (i + sz) xs in
  go 4 args

let push_local_vars vars =
  let go = function
    | Decl (NoLink, ((TFun _) as ty), name, _)
    | Decl (Extern, ty, name, _) ->
       push env_ref (name, (ty, Global (name, 0)))
    | Decl (NoLink, ty, name, _) ->
       sp_offset_ref := aligned ty !sp_offset_ref + sizeof ty;
       push env_ref (name, (ty, Mem (31, - !sp_offset_ref)))
    | Decl (Static, ty, name, _) ->
       let label_id = label_create () in
       let label = sprintf "L_%s_%d" name label_id in
       push env_ref (name, (ty, Global (label, 0))) in
  List.iter go vars

let escaped l =
  let esc_char = function
    | 0 -> "\\0"
    | 7 -> "\\a"
    | 8 -> "\\b"
    | 9 -> "\\t"
    | 10 -> "\\n"
    | 11 -> "\\v"
    | 12 -> "\\f"
    | 13 -> "\\r"
    | 34 -> "\\\""
    | 92 -> "\\\\"
    | c when c < 32 || c = 127 -> sprintf "\\x%02x" c
    | c -> sprintf "%c" (Char.chr c) in
  String.concat "" (List.map esc_char l)

let emit_global_var name init =
  let contents = ref [] in
  emit_raw "%s:\n" name;
  let rec go = function
    | EConst (ty, VInt v) ->
      begin match sizeof ty with
      | 1 -> emit ".byte %d" v
      | 2 -> emit ".short %d" v
      | 4 -> emit ".int %d" v
      | _ -> raise_error "emit_global_var: invalid int constant (size = %d)" (sizeof ty)
      end
    | EConst (_, VFloat v) ->
       let v = if v = 0.0 then 0.0 else v in
       emit ".float %.15F" v
    | EConst (_, VStr v) ->
       emit ".string \"%s\"" (escaped v)
    | EAddr (TPtr TChar, EConst (_, VStr s)) ->
       contents := s :: !contents;
       emit ".int %s_contents_%d" name (List.length !contents)
    | EAddr (TPtr _, EVar (_, name)) when List.mem_assoc name !env_ref ->
       emit ".int %s" name
    | ECast (TPtr _, TPtr _, e) ->
       go e
    | ESpace ty ->
       emit ".space %d" (sizeof ty)
    | _ -> raise_error "global initializer must be constant" in
  List.iter go init;
  List.iteri
    (fun i s ->
     emit_raw "%s_contents_%d:\n" name (i + 1);
     emit ".string \"%s\"" (escaped s))
    (List.rev !contents);
  emit ".align 4"

let emit_native_call ret_reg func arg1 arg2 =
  is_leaf_function := false;
  let used_reg = List.filter (fun x -> x != ret_reg) (get_used_reg ()) in
  let size = 4 * (List.length used_reg + 2) in
  emit "sub rsp, rsp, %d" size;
  emit "mov [rsp], r%d" arg1;
  emit "mov [rsp + 4], r%d" arg2;
  List.iteri (fun i -> emit "mov [rsp + %d], r%d" (4 * i + 8)) used_reg;
  emit "call %s" func;
  reg_free_all ();
  reg_use ret_reg;
  if ret_reg != 1 then
    emit "mov r%d, r1" ret_reg;
  List.iteri
    (fun i n ->
     reg_use n;
     emit "mov r%d, [rsp + %d]" n (4 * i + 8))
    used_reg;
  emit "add rsp, rsp, %d" size

let sgn_ext reg = function
  | TChar -> emit "sextb r%d, r%d" reg reg
  | TUChar -> emit "zextb r%d, r%d" reg reg
  | TShort -> emit "sextw r%d, r%d" reg reg
  | TUShort -> emit "zextw r%d, r%d" reg reg
  | _ -> ()

let show_disp disp =
  if disp > 0 then sprintf " + %d" disp else
  if disp < 0 then sprintf " - %d" (-disp) else ""

let rec show_strg = function
  | Reg 30 -> "rsp"
  | Reg 31 -> "rbp"
  | Reg r  -> sprintf "r%d" r
  | Mem (base, ofs) ->
    if base = 0 then sprintf "[%#x]" (ofs land 0xffffffff) else
    sprintf "[%s%s]" (show_strg (Reg base)) (show_disp ofs)
  | Global (l, ofs) ->
    sprintf "[%s%s]" l (show_disp ofs)

let rec emit_mov ty mem1 mem2 =
  let go n = function
    | Mem    (b, d) -> Mem    (b, d + n)
    | Global (b, d) -> Global (b, d + n)
    | Reg _ -> raise_error "emit_mov: go" in
  match mem1, mem2, sizeof ty with
  | _, _, 4 ->
     emit "mov %s, %s" (show_strg mem1) (show_strg mem2)
  | Reg r, _, 1 ->
     emit "movb r%d, %s" r (show_strg mem2);
     if ty = TUChar then sgn_ext r ty
  | _, Reg r, 1 ->
     emit "movb %s, r%d" (show_strg mem1) r
  | Reg r, _, 2 ->
     let reg = reg_alloc () in (* Reg r may appear in mem2 *)
     emit "movb r%d, %s" reg (show_strg (go 0 mem2));
     emit "movb r%d, %s" r (show_strg (go 1 mem2));
     emit "zextb r%d, r%d" reg reg;
     emit "shl r%d, r%d, 8" r r;
     emit "or r%d, r%d, r%d" r r reg;
     if ty = TUShort then sgn_ext r ty;
     reg_free reg
  | _, Reg r, 2 ->
     let reg = reg_alloc () in (* Don't pollute Reg r *)
     emit "movb %s, r%d" (show_strg (go 0 mem1)) r;
     emit "shr r%d, r%d, 8" reg r;
     emit "movb %s, r%d" (show_strg (go 1 mem1)) reg;
     reg_free reg
  | _, _, sz ->
     let reg = reg_alloc () in
     for i = 0 to sz / 4 - 1 do
       emit "mov r%d, %s" reg (show_strg (go (i * 4) mem2));
       emit "mov %s, r%d" (show_strg (go (i * 4) mem1)) reg
     done;
     reg_free reg

let rec int_const = function
  | EConst (_, VInt i) -> Some i
  | ECast (t1, t2, e) ->
     if not (is_integral t1 || is_pointer t1) then None else
     if not (is_integral t2 || is_pointer t2) then None else
     int_const e
  | EUnary (_, op, e) ->
     if op = PostInc || op = PostDec then None else
     opMap (unary2fun op) (int_const e)
  | _ -> None

let rec ex ret_reg = function
  | ENil -> ()
  | EComma(_, ex1, ex2) ->
     ex ret_reg ex1;
     ex ret_reg ex2
  | EConst (ty, v) ->
     begin match v with
     | VInt i ->
        emit "mov r%d, %d" ret_reg i
     | VFloat f ->
        let f = if f = 0.0 then 0.0 else f in
        emit "mov r%d, %F" ret_reg f
     | VStr _ ->
        raise_error "logic flaw: EConst at Emitter.ex"
     end
  | ECond (_, c, t, e) ->
     let lelse = label_create () in
     let lend = label_create () in
     ex ret_reg c;
     emit "bz r%d, L%d" ret_reg lelse;
     ex ret_reg t;
     emit "br L%d" lend;
     emit_label lelse;
     ex ret_reg e;
     emit_label lend
  | EArith (ty, op, e1, e2) ->
     begin match op with
     | Mul | Div | Mod ->
        let log2 n =
          let rec go n acc =
            if n <= 1 then acc else go (n / 2) (acc + 1) in
          go n 0 in
        begin match int_const e1, int_const e2 with
        | _, Some x when x land (x - 1) = 0 ->
           ex ret_reg e1;
           begin match op, ty with
           | Mul, _ | Div, _ when x = 1 ->
              ()
           | Mul, _ when x = 0 ->
              emit "mov r%d, 0" ret_reg
           | Mod, _ when x = 1 ->
              emit "mov r%d, 0" ret_reg
           | Mul, _ ->
              emit "shl r%d, r%d, %d" ret_reg ret_reg (log2 x)
           | Div, t when is_unsigned t ->
              emit "shr r%d, r%d, %d" ret_reg ret_reg (log2 x)
           | Div, _ ->
              let reg = reg_alloc () in
              if x = 2 then
                emit "shr r%d, r%d, 31" reg ret_reg
              else begin
                emit "sar r%d, r%d, 31" reg ret_reg;
                emit "shr r%d, r%d, %d" reg reg (32 - log2 x)
              end;
              emit "add r%d, r%d, r%d" ret_reg ret_reg reg;
              emit "sar r%d, r%d, %d" ret_reg ret_reg (log2 x);
              reg_free reg
           | Mod, t when is_unsigned t ->
              emit "and r%d, r%d, %d" ret_reg ret_reg (x - 1)
           | Mod, _ ->
              let reg = reg_alloc () in
              if x = 2 then
                emit "shr r%d, r%d, 31" reg ret_reg
              else begin
                emit "sar r%d, r%d, 31" reg ret_reg;
                emit "shr r%d, r%d, %d" reg reg (32 - log2 x)
              end;
              emit "add r%d, r%d, r%d" ret_reg ret_reg reg;
              emit "and r%d, r%d, %d" ret_reg ret_reg (x - 1);
              emit "sub r%d, r%d, r%d" ret_reg ret_reg reg;
              reg_free reg
           | _ ->
              assert false
           end
        | Some x, _ when x land (x - 1) = 0 && op = Mul ->
           ex ret_reg (EArith (ty, op, e2, e1))
        | _ ->
           let fun_name =
             match op, ty with
             | Div, t when is_unsigned t -> "__unsigned_div"
             | Mod, t when is_unsigned t -> "__unsigned_mod"
             | Mul, _ -> "__mul"
             | Div, _ -> "__signed_div"
             | Mod, _ -> "__signed_mod"
             | _ -> assert false in
           ex ret_reg e1;
           let reg = reg_alloc () in
           ex reg e2;
           emit_native_call ret_reg fun_name ret_reg reg;
           reg_free reg
        end
     | _ ->
        let op = match op with
          | Add    -> "add"
          | Sub    -> "sub"
          | BitAnd -> "and"
          | BitOr  -> "or"
          | BitXor -> "xor"
          | LShift -> "shl"
          | RShift -> if is_unsigned ty then "shr" else "sar"
          | _ -> assert false in
        emit_bin ret_reg op e1 e2
     end
  | EFArith (ty, Div, e1, e2) ->
     let reg = reg_alloc () in
     ex ret_reg e1;
     ex reg e2;
     emit "finv r%d, r%d" reg reg;
     emit "fmul r%d, r%d, r%d" ret_reg ret_reg reg;
     reg_free reg
  | EFArith (ty, op, e1, e2) ->
     let op = match op with
       | Add -> "fadd"
       | Sub -> "fsub"
       | Mul -> "fmul"
       | _ -> assert false in
     emit_bin ret_reg op e1 e2
  | ERel (_, op, e1, e2) ->
     let op = match op with
       | Le -> "cmple"
       | Lt -> "cmplt"
       | Ge -> "cmpge"
       | Gt -> "cmpgt" in
     emit_bin ret_reg op e1 e2
  | EURel (_, op, e1, e2) ->
     let op = match op with
       | Le -> "cmpule"
       | Lt -> "cmpult"
       | Ge -> "cmpuge"
       | Gt -> "cmpugt" in
     emit_bin ret_reg op e1 e2
  | EFRel (_, op, e1, e2) ->
     let op = match op with
       | Le -> "fcmple"
       | Lt -> "fcmplt"
       | Ge -> "fcmpge"
       | Gt -> "fcmpgt" in
     emit_bin ret_reg op e1 e2
  | EEq   (_, op, e1, e2)
  | EFEq  (_, op, e1, e2) ->
     let op = match op with
       | Eq -> "cmpeq"
       | Ne -> "cmpne" in
     emit_bin ret_reg op e1 e2
  | EPAdd (ty, e1, e2) ->
     begin match ty with
     | TPtr ty ->
        if ty = TVoid then
          raise_error "EPAdd : addition of void* is unsupported";
        ex ret_reg e1;
        begin match e2 with
        | EConst (_, VInt i) ->
           emit "add r%d, r%d, %d" ret_reg ret_reg (sizeof ty * i)
        | _ ->
           let reg = reg_alloc () in
           ex reg e2;
           ex reg (EArith (TInt, Mul, ENil, EConst (TInt, VInt (sizeof ty))));
           emit "add r%d, r%d, r%d" ret_reg ret_reg reg;
           reg_free reg
        end
     | _ ->
        failwith "EPAdd"
     end
  | EPDiff (_, e1, e2) ->
     begin match (typeof e1, typeof e2) with
     | (TPtr t1, TPtr t2) when t1 = t2 ->
        if t1 = TVoid then
          raise_error "EPDiff : subtraction of void* is unsupported";
        ex ret_reg e1;
        let reg = reg_alloc () in
        ex reg e2;
        emit "sub r%d, r%d, r%d" ret_reg ret_reg reg;
        emit "mov r%d, %d" reg (sizeof t1);
        emit_native_call ret_reg "__signed_div" ret_reg reg;
        reg_free reg
     | _ ->
        failwith "EPDiff"
     end
  | ELog (_, op, e1, e2) ->
     begin match op with
     | LogAnd ->
        let l1 = label_create () in
        let l2 = label_create () in
        ex ret_reg e1;
        emit "bz r%d, L%d" ret_reg l1;
        ex ret_reg e2;
        emit "bz r%d, L%d" ret_reg l1;
        emit "mov r%d, 1" ret_reg;
        emit "br L%d" l2;
        emit_label l1;
        emit "mov r%d, 0" ret_reg;
        emit_label l2
     | LogOr ->
        let l1 = label_create () in
        let l2 = label_create () in
        ex ret_reg e1;
        emit "bnz r%d, L%d" ret_reg l1;
        ex ret_reg e2;
        emit "bnz r%d, L%d" ret_reg l1;
        emit "br L%d" l2;
        emit_label l1;
        emit "mov r%d, 1" ret_reg;
        emit_label l2
     end
  | EUnary (ty, op, e) ->
     begin match op with
     | Plus ->
        ex ret_reg e
     | Minus ->
        ex ret_reg e;
        emit "neg r%d, r%d" ret_reg ret_reg
     | BitNot ->
        ex ret_reg e;
        emit "not r%d, r%d" ret_reg ret_reg
     | PostInc
     | PostDec ->
        let areg = reg_alloc () in
        let mem = emit_lv_addr areg e in
        let reg = reg_alloc () in
        emit_mov ty (Reg ret_reg) mem;
        if op = PostInc then
          emit "add r%d, r%d, 1" reg ret_reg
        else
          emit "sub r%d, r%d, 1" reg ret_reg;
        sgn_ext reg ty;
        emit_mov ty mem (Reg reg);
        reg_free areg;
        reg_free reg
     end
  | EFUnary (_, op, e) ->
     begin match op with
     | Plus ->
        ex ret_reg e
     | Minus ->
        ex ret_reg e;
        emit "xor r%d, r%d, 0x80000000" ret_reg ret_reg
     | _ ->
        raise_error "FUnary"
     end
  | EPPost (TPtr ty, op, e) ->
     if ty = TVoid then
       raise_error "EPPost : ++/-- of void* is unsupported";
     let areg = reg_alloc () in
     let mem = emit_lv_addr areg e in
     let reg = reg_alloc () in
     emit_mov (TPtr ty) (Reg ret_reg) mem;
     if op = Inc then
       emit "add r%d, r%d, %d" reg ret_reg (sizeof ty)
     else
       emit "sub r%d, r%d, %d" reg ret_reg (sizeof ty);
     emit_mov (TPtr ty) mem (Reg reg);
     reg_free areg;
     reg_free reg
  | EPPost _ ->
     raise_error "EPPost: not pointer"
  | EAsm (_, asm) ->
     let slist = List.map (Char.chr >> String.make 1) asm in
     emit_raw "%s" (String.concat "" slist)
  | ECall (_, f, exlst) ->
     is_leaf_function := false;
     let used_reg = List.filter (fun x -> x != ret_reg) (get_used_reg ()) in
     let arg_list =
       let go e =
         let reg = reg_alloc () in
         let ty = if sizeof (typeof e) <= 4 then TInt else typeof e in
         ex reg e;
         (ty, reg) in
       List.map go exlst in
     let callee = match f with
       | EAddr (_, EVar (TFun _, name)) -> name
       | _ ->
          let fun_reg = reg_alloc () in
          ex fun_reg f;
          sprintf "r%d" fun_reg in
     let argsize = sum_of (List.map (fst >> sizeof) arg_list) in
     let size = 4 * List.length used_reg + argsize in
     if size > 0 then
       emit "sub rsp, rsp, %d" size;
     (* push arguments *)
     ignore (List.fold_left
       (fun n (ty, reg) ->
         if ty = TInt then
           emit "mov [rsp%s], r%d" (show_disp n) reg
         else (* reg has an address *)
           emit_mov ty (Mem (30, n)) (Mem (reg, 0));
         n + sizeof ty) 0 arg_list);
     (* save registers *)
     List.iteri
       (fun i -> emit "mov [rsp%s], r%d" (show_disp (4 * i + argsize)))
       used_reg;
     emit "call %s" callee;
     reg_free_all ();
     reg_use ret_reg;
     if ret_reg != 1 then
       emit "mov r%d, r1" ret_reg;
     (* restore registers *)
     List.iteri
       (fun i n ->
         reg_use n;
         emit "mov r%d, [rsp%s]" n (show_disp (4 * i + argsize)))
       used_reg;
     (* clean stack *)
     if size > 0 then
       emit "add rsp, rsp, %d" size
  | EVar (ty, name)
  | EDot (ty, _, name) as expr ->
     begin match ty with
     | TVoid | TArray _ | TFun _ ->
        raise_error "logic flaw: EVar"
     | _ ->
        if sizeof ty > 4 then
          ex ret_reg (EAddr (TPtr ty, expr))
        else
          let mem = emit_lv_addr ret_reg expr in
          emit_mov ty (Reg ret_reg) mem
     end
  | EAssign (ty, op, e1, e2) ->
     let reg = reg_alloc () in
     let mem = emit_lv_addr reg e1 in
     begin match op with
     | None ->
        ex ret_reg e2;
        if sizeof ty > 4 then
          emit_mov ty mem (Mem (ret_reg, 0))
        else
          emit_mov ty mem (Reg ret_reg)
     | Some op ->
        emit_mov ty (Reg ret_reg) mem;
        begin match op, ty with
        | Add, TPtr _ ->
           ex ret_reg (EPAdd (ty, ENil, e2));
        | _ ->
           let ty' = from_some (Typing.arith_conv (ty, typeof e2)) in
           ex ret_reg (EArith (ty', op, ENil, e2));
           sgn_ext ret_reg ty
        end;
        emit_mov ty mem (Reg ret_reg)
     end;
     reg_free reg
  | EFAssign (ty, op, e1, e2) ->
     let reg = reg_alloc () in
     let mem = emit_lv_addr reg e1 in
     begin match op with
     | None ->
        ex ret_reg e2
     | Some op ->
        emit_mov ty (Reg ret_reg) mem;
        let ty' = from_some (Typing.arith_conv (ty, typeof e2)) in
        ex ret_reg (EFArith (ty', op, ENil, e2))
     end;
     emit_mov ty mem (Reg ret_reg);
     reg_free reg
  | EAddr (_, e) ->
     begin match emit_lv_addr ret_reg e with
     | Reg reg ->
        if ret_reg <> reg then raise_error "EAddr: reg"
     | Mem (reg, 0) when ret_reg = reg ->
        ()
     | Mem (reg, ofs) ->
        let r = if reg = 31 then "rbp" else sprintf "r%d" reg in
        if ofs > 0 then emit "add r%d, %s, %d" ret_reg r ofs else
        if ofs < 0 then emit "sub r%d, %s, %d" ret_reg r (-ofs) else
        emit "mov r%d, r%d" ret_reg reg
     | Global (l, ofs) ->
        emit "mov r%d, %s%s" ret_reg l (show_disp ofs)
     end
  | EPtr (ty, e) when sizeof ty > 4 ->
     ex ret_reg e;
  | EPtr (ty, EConst (_, VInt i)) ->
     emit_mov ty (Reg ret_reg) (Mem (0, i))
  | EPtr (ty, EPAdd (_, e, EConst (_, VInt i))) ->
     ex ret_reg e;
     emit_mov ty (Reg ret_reg) (Mem (ret_reg, i * sizeof ty))
  | EPtr (ty, e) ->
     ex ret_reg e;
     emit_mov ty (Reg ret_reg) (Mem (ret_reg, 0))
  | ECast (t1, t2, e) ->
     begin match t1, t2 with
     | _, _ when not (t1 = TVoid || (is_scalar t1 && is_scalar t2)) ->
        raise_error "ECast: %s, %s" (pp_type t1) (pp_type t2)
     | _, _ when t1 = t2 || t1 = TVoid ->
        ex ret_reg e
     | t1, t2 when is_real t1 && is_integral t2 -> (* int -> float *)
        if is_unsigned t2 then
          raise_error "ECast: unsigned -> float is unsupported";
        ex ret_reg e;
        emit "itof r%d, r%d" ret_reg ret_reg
     | t1, t2 when is_integral t1 && is_real t2 -> (* float -> int *)
        if is_unsigned t1 then
          raise_error "ECast: float -> unsigned is unsupported";
        ex ret_reg e;
        let flg = reg_alloc () in
        emit "sar r%d, r%d, 31" flg ret_reg;    (* flg=ret<0?-1:0 *)
        emit "shl r%d, r%d, 1"  ret_reg ret_reg;
        emit "shr r%d, r%d, 1"  ret_reg ret_reg;(* fabs(ret_reg)*)
        emit "floor r%d, r%d" ret_reg ret_reg;
        emit "ftoi  r%d, r%d" ret_reg ret_reg;
        (* (x^flg)-flg equals (flg==-1?-x:x) *)
        emit "xor r%d, r%d, r%d" ret_reg ret_reg flg;
        emit "sub r%d, r%d, r%d" ret_reg ret_reg flg;
        sgn_ext ret_reg t1;
        reg_free flg
     | t1, t2 when is_real t1 && is_real t2 ->
        ex ret_reg e
     | t1, t2 when is_real t1 || is_real t2 ->
        raise_error "ECast: float"
     | _ ->
        ex ret_reg e;
        sgn_ext ret_reg t1
     end
  | ESpace _ ->
     raise_error "ex: ESpace"

and emit_bin ret_reg op e1 e2 =
  match int_const e1, int_const e2 with
  | _, Some n ->
     ex ret_reg e1;
     emit "%s r%d, r%d, %d" op ret_reg ret_reg n
  | Some n, _ when List.mem op ["add"; "and"; "or"; "xor"; "cmpeq"; "cmpne"] ->
     ex ret_reg e2;
     emit "%s r%d, r%d, %d" op ret_reg ret_reg n
  | _ ->
     ex ret_reg e1;
     let reg = reg_alloc () in
     ex reg e2;
     emit "%s r%d, r%d, r%d" op ret_reg ret_reg reg;
     reg_free reg

and emit_lv_addr reg = function (* address of left *)
  | EVar (ty, name) ->
    snd (resolve_var name)
  | EDot (ty, expr, mem) ->
    begin match typeof expr with
    | TStruct s_id ->
      let rec go i s = function
        | [] -> failwith "edot"
        | (v, _) :: _ when v = s -> aligned ty i
        | (_, ty) :: xs -> go (aligned ty i + sizeof ty) s xs in
      let memlist = List.nth !struct_env s_id in
      let mem_offset = go 0 mem memlist in
      begin match emit_lv_addr reg expr with
      | Mem (reg, ofs) -> Mem (reg, ofs + mem_offset)
      | Global (label, ofs) -> Global (label, ofs + mem_offset)
      | Reg _ -> failwith "emit_lv_addr: EDot (struct)"
      end
    | TUnion _ ->
      emit_lv_addr reg expr
    | _ -> raise_error "emit_lv_addr: EDot"
    end
  | EPtr (ty, EConst (_, VInt i)) ->
    Mem (0, i)
  | EPtr (ty, EPAdd (_, e, EConst (_, VInt i))) ->
    ex reg e;
    Mem (reg, i * sizeof ty)
  | EPtr (ty, e) ->
    ex reg e;
    Mem (reg, 0)
  | EConst (_, VStr s) ->
    let label = sprintf "L%d" (label_create ()) in
    push static_locals_ref (label, [EConst (TVoid, VStr s)]);
    emit "mov r%d, %s" reg label;
    Mem (reg, 0)
  | _ ->
    raise_error "this expr is not lvalue"

let init_local_vars vars =
  let go (Decl (ln, ty, name, init)) =
    match resolve_var name with
    | (_, Reg _) ->
       raise_error "logic flaw: init_local_vars Reg"
    | (_, Mem (31, offset)) ->
       let reg = reg_alloc () in
       let go2 n e =
         let ty = typeof e in
         let n = aligned ty n in
         if sizeof ty <= 4 then begin
           ex reg e;
           emit_mov ty (Mem (31, offset + n)) (Reg reg)
         end else begin
           let mem = emit_lv_addr reg e in
           emit_mov ty (Mem (31, offset + n)) mem
         end;
         n + sizeof ty in
       ignore (List.fold_left go2 0 init);
       reg_free reg
    | (_, Mem _) ->
       raise_error "logic flaw: init_local_vars Mem"
    | (_, Global (label, _)) ->
       match (ln, init) with
       | Static, [] ->
          push static_locals_ref (label, [ESpace ty])
       | Static, xs ->
          push static_locals_ref (label, xs)
       | Extern, [] | NoLink, [] ->
          ()                   (* ignore *)
       | Extern, _ | NoLink, _ ->
          raise_error"local extern variable has initializer" in
  List.iter go vars

let const_bool = function
  | EConst (_, VInt i) -> Some (i <> 0)
  | EConst (_, VFloat f) -> Some (f <> 0.0)
  | _ -> None

let rec st = function
  | SNil ->
     ()
  | SBlock (vars, stmts) ->
     let old_sp = !sp_offset_ref in
     let old_env = !env_ref in
     push_local_vars vars;
     init_local_vars vars;
     List.iter st stmts;
     sp_offset_ref := old_sp;
     env_ref := old_env;
  | SWhile (cond, b) ->
     let loop = const_bool cond = Some true in
     let beginlabel = label_create () in
     let condlabel = label_create () in
     let endlabel = label_create () in
     let continue_flg = !continue_flg_ref in
     let break_flg = !break_flg_ref in
     push con_stack (if loop then beginlabel else condlabel);
     push brk_stack endlabel;
     break_flg_ref := false;
     if not loop then
       emit "br L%d" condlabel;
     emit_label beginlabel;
     st b;
     if loop then
       emit "br L%d" beginlabel
     else begin
       emit_label condlabel;
       let cond_reg = reg_alloc () in
       ex cond_reg cond;
       emit "bnz r%d, L%d" cond_reg beginlabel;
       reg_free cond_reg
     end;
     if !break_flg_ref then
       emit_label endlabel;
     continue_flg_ref := continue_flg;
     break_flg_ref := break_flg;
     pop con_stack;
     pop brk_stack
  | SDoWhile (b, cond) when const_bool cond = Some false ->
     st b
  | SDoWhile (b, cond) ->
     let beginlabel = label_create () in
     let condlabel = label_create () in
     let endlabel = label_create () in
     let continue_flg = !continue_flg_ref in
     let break_flg = !break_flg_ref in
     push con_stack condlabel;
     push brk_stack endlabel;
     continue_flg_ref := false;
     break_flg_ref := false;
     emit_label beginlabel;
     st b;
     if !continue_flg_ref then
       emit_label condlabel;
     let cond_reg = reg_alloc () in
     ex cond_reg cond;
     emit "bnz r%d, L%d" cond_reg beginlabel;
     reg_free cond_reg;
     if !break_flg_ref then
       emit_label endlabel;
     continue_flg_ref := continue_flg;
     break_flg_ref := break_flg;
     pop con_stack;
     pop brk_stack
  | SFor(init, cond, iter, b) ->
     let loop = cond = None || const_bool (from_some cond) = Some true in
     let startlnum = label_create () in
     let iterlnum = label_create () in
     let condlnum = if loop then 0 else label_create () in
     let endlnum = label_create () in
     let continue_flg = !continue_flg_ref in
     let break_flg = !break_flg_ref in
     push con_stack iterlnum;
     push brk_stack endlnum;
     continue_flg_ref := false;
     break_flg_ref := false;
     if is_some init then begin
       let temp = reg_alloc () in
       ex temp (from_some init);
       reg_free temp
     end;
     if not loop then
       emit "br L%d" condlnum;
     emit_label startlnum;
     st b;
     if is_some iter then begin
       if !continue_flg_ref then
         emit_label iterlnum;
       let temp = reg_alloc () in
       ex temp (from_some iter);
       reg_free temp
     end;
     if loop then
       emit "br L%d" startlnum
     else begin
       emit_label condlnum;
       let cond_reg = reg_alloc () in
       ex cond_reg (from_some cond);
       emit "bnz r%d, L%d" cond_reg startlnum;
       reg_free cond_reg
     end;
     if !break_flg_ref then
       emit_label endlnum;
     continue_flg_ref := continue_flg;
     break_flg_ref := break_flg;
     pop con_stack;
     pop brk_stack
  | SIfElse (cond, b1, b2) ->
     let cond_reg = reg_alloc () in
     ex cond_reg cond;
     let lnum = label_create () in
     let endlnum = label_create () in
     emit "bz r%d, L%d" cond_reg lnum;
     reg_free cond_reg;
     st b1;
     if b2 <> SNil then
       emit "br L%d" endlnum;
     emit_label lnum;
     if b2 <> SNil then begin
       st b2;
       emit_label endlnum
     end
  | SReturn exp ->
     begin match exp with
     | Some exp ->
        let reg = reg_alloc () in
        ex reg exp;
        if reg != 1 then
          emit "mov r1, r%d" reg;
        reg_free reg
     | None ->
        ()
     end;
     emit "leave";
     emit "ret";
  | SContinue ->
     let lbl = peek con_stack in
     emit "br L%d" lbl;
     continue_flg_ref := true
  | SBreak ->
     let lbl = peek brk_stack in
     emit "br L%d" lbl;
     break_flg_ref := true
  | SLabel (label, s) ->
     emit_raw "%s:\n" (escape_label label);
     st s
  | SGoto label ->
     emit "br %s" (escape_label label)
  | SCase i ->
     switch_cases := (i :: peek switch_cases) :: List.tl !switch_cases;
     emit_raw "%s:\n" (escape_case i)
  | SDefault ->
     peek switch_defaults := true;
     emit_raw "%s:\n" (escape_default ())
  | SSwitch (e,s) ->
     let break_flg = !break_flg_ref in
     switch_counter := !switch_counter + 1;
     switch_stack := !switch_counter :: !switch_stack;
     switch_cases := [] :: !switch_cases;
     switch_defaults := ref false :: !switch_defaults;
     let l1 = label_create () in
     let l2 = label_create () in
     emit "br L%d" l1;
     push brk_stack l2;
     st s;
     pop brk_stack;
     emit "br L%d" l2;
     (* dispatcher *)
     emit_label l1;
     let lreg = reg_alloc () in
     ex lreg e;
     let rreg = reg_alloc () in
     List.iter
       (fun i ->
        emit "mov r%d, %d" rreg i;
        emit "beq r%d, r%d, %s" lreg rreg (escape_case i))
       (List.rev (peek switch_cases));
     reg_free lreg;
     reg_free rreg;
     if !(peek switch_defaults) then
       emit "br %s" (escape_default ());
     emit_label l2;
     break_flg_ref := break_flg;
     switch_defaults := List.tl !switch_defaults;
     switch_cases := List.tl !switch_cases;
     switch_stack := List.tl !switch_stack
  | SExpr exp ->
     let temp = reg_alloc () in
     ex temp exp;
     reg_free temp

let emitter oc = function
  | DefFun(Decl(ln, ty, name, _), args, b) ->
     fun_name_ref := name;
     is_leaf_function := true;
     push env_ref (name, (ty, Global (name, 0)));
     let old_env = !env_ref in
     push_args args;
     if ln <> Static then
       emit_raw ".global %s\n" name;
     emit_raw "%s:\n" name;
     begin match b with
     | SBlock ([], [SExpr (EAsm _)]) -> ()
     | _ -> emit "enter %d" (sizeof_block b)
     end;
     st b;
     begin match b with
     | SBlock ([], [SExpr (EAsm _)]) -> ()
     | _ -> insert_epilogue ()
     end;
     if name = "main" then
       insert_halt ();
     List.iter
       (fun (name, e) -> emit_global_var name e)
       (List.rev !static_locals_ref);
     flush_buffer oc;
     env_ref := old_env;
     static_locals_ref := []
  | DefVar (Decl (ln, ty, name, init)) ->
     push env_ref (name, (ty, Global (name, 0)));
     begin match (ln, init) with
     | NoLink, [] when not (is_funty ty) ->
        emit_raw ".global %s\n" name;
        emit_global_var name [ESpace ty]
     | Static, [] when not (is_funty ty) ->
        emit_global_var name [ESpace ty]
     | NoLink, []
     | Extern, []
     | Static, [] ->
        ()                     (* ignore *)
     | NoLink, xs
     | Extern, xs ->
        emit_raw ".global %s\n" name;
        emit_global_var name xs
     | Static, xs ->
        emit_global_var name xs
     end;
     flush_buffer oc

let main oc defs =
  List.iter (emitter oc) defs
