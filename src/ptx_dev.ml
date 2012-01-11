open Llvm
open Ir
open Ir_printer
open Util
open Cg_llvm_util
open Analysis
open Constant_fold

let shared_addrspace = 4

type state = {
  shared_mem_bytes : int ref;
  first_block : bool ref;
}
type context = state cg_context
let start_state () =
  let sh = 0 in
  let fst = true in
  {
    shared_mem_bytes = ref sh;
    first_block = ref fst;
  }
(* TODO: track current surrounding thread/block nest scope.
 * should allow malloc to compute correct offsets. *)

let is_simt_var name =
  let name = base_name name in
  List.exists
    (fun v -> name = v)
    ["threadidx"; "threadidy"; "threadidz"; "threadidw"; "blockidx"; "blockidy"; "blockidz"; "blockidz"]

exception Unknown_intrinsic of string

let pointer_size = 8

(* TODO: replace references to loop bounds with blockDim, gridDim? *)
let simt_intrinsic name =
  (* TODO: pass through dotted extern function names *)
  match base_name name with
    | "threadidx" -> ".llvm.ptx.read.tid.x"
    | "threadidy" -> ".llvm.ptx.read.tid.y"
    | "threadidz" -> ".llvm.ptx.read.tid.z"
    | "threadidw" -> ".llvm.ptx.read.tid.w"
    | "blockidx"  -> ".llvm.ptx.read.ctaid.x"
    | "blockidy"  -> ".llvm.ptx.read.ctaid.y"
    | "blockidz"  -> ".llvm.ptx.read.ctaid.z"
    | "blockidw"  -> ".llvm.ptx.read.ctaid.w"
    | n -> raise (Unknown_intrinsic n)
    (* Can also support:
        laneid
        warpid
        nwarpid
        smid
        nsmid
        gridid
        clock
        clock64
        pm0
        pm1
        pm2
        pm3 *)

let rec cg_expr con = function
  | Debug (e, _, _) ->
      Printf.printf "Skipping Debug expr inside device kernel\n%!";
      cg_expr con e
  | e -> con.cg_expr e

let rec cg_stmt con = function
  | Print _ ->
      Printf.printf "Dropping Print stmt inside device kernel\n%!";
      const_zero con.c (* ignorable return value *)
  | For (name, base, width, ordered, body) when is_simt_var name ->
      (* TODO: loop needs to be turned into If (which we don't have in our IR), not dropped *)
      Printf.eprintf "Dropping %s loop on %s (%s..%s)\n%!"
        (if ordered then "serial" else "parallel") name (string_of_expr base) (string_of_expr width);
      assert (not ordered);

      let b = con.b
      and c = con.c
      and cg_expr = cg_expr con
      and cg_stmt = cg_stmt con
      and sym_add = con.sym_add
      and sym_remove = con.sym_remove in
      
      (* Issue a thread barrier to complete prior ParFor *)
      (* TODO: this can be optimized out for cases where we don't share chunks downstream *)
      begin match base_name name with
        (* | "threadidx" *)
        | "threadidy"
        | "threadidz"
        | "threadidw" ->
          if not !(con.arch_state.first_block) then begin
            let barrier = match base_name name with
              (* | "threadidx" -> 1 *)
              | "threadidy" -> 0
              | n -> failwith ("No barriers defined for ParFor over " ^ n)
            in
            let syncthreads = match lookup_function "llvm.ptx.bar.sync" con.m with
              | Some f -> f
              | None -> failwith "failed to find llvm.ptx.bar.sync intrinsic"
            in
            ignore (build_call syncthreads [| const_int (i32_type con.c) barrier |] "" con.b)
          end;
          con.arch_state.first_block := false
        | _ -> ()
      end;

      (* Drop this explicit loop, and just SIMTfy variable references in its body *)
      (* Add base to all references to name inside loop, since CTA and Thread IDs start from 0 *)
      let simtvar = (Call (i32, simt_intrinsic name, [])) in
      let loopvar = simtvar +~ base in

      (* create the basic blocks for the (start of the) loop body, and continuing after the loop *)
      let the_function = block_parent (insertion_block b) in
      let loop_bb = append_block c (name ^ "_simt_loop") the_function in
      let after_bb = append_block c (name ^ "_simt_afterloop") the_function in
      
      (* conditionally jump into the loop, if our thread corresponds to a valid iteration *)
      let cond = Cmp(LT, simtvar, width) in
      Printf.eprintf " for -> if (%s)\n%!" (string_of_expr cond);
      (* dump_module con.m; *)

      ignore (build_cond_br (cg_expr cond) loop_bb after_bb b);
      (* ignore (build_br loop_bb b); *)

      (* Start insertion in loop_bb. *)
      position_at_end loop_bb b;

      (* push the loop variable into scope *)
      sym_add name (cg_expr loopvar);

      (* codegen the body *)
      ignore (cg_stmt body);

      (* pop the loop variable *)
      sym_remove name;

      (* Insert branch out of if. *)
      ignore (build_br after_bb b);

      (* Any new code will be inserted in after_bb. *)
      position_at_end after_bb b;
      
      (* Return an ignorable llvalue *)
      const_int (i32_type c) 0

  | stmt -> con.cg_stmt stmt

let rec codegen_entry dev_ctx dev_mod cg_entry entry =
  failwith "Direct use of Ptx_dev.codegen_entry is not supported"

let malloc con name count elem_size =
  let zero = const_zero con.c in
  let size = match constant_fold_expr (count *~ elem_size) with
    | IntImm sz -> sz
    | _ -> failwith ""
  in
  Printf.printf "malloc %s[%d bytes] on PTX device\n%!" name size;
  con.arch_state.shared_mem_bytes := !(con.arch_state.shared_mem_bytes) + size;
  let elemty = element_type (raw_buffer_t con.c) in
  let ty = array_type elemty size in
  let init = undef ty in
  let buf = define_qualified_global name init shared_addrspace con.m in
  build_gep buf [| zero; zero |] (name ^ ".buf_base") con.b

let free con ptr =
  (* Return an ignorable llvalue *)
  const_zero con.c

let env =
  let ntid_decl   = (".llvm.ptx.read.ntid.x", [], i32, Extern) in
  let nctaid_decl = (".llvm.ptx.read.nctaid.x", [], i32, Extern) in

  let e = Environment.empty in
  let e = Environment.add "llvm.ptx.read.nctaid.x" nctaid_decl e in
  let e = Environment.add "llvm.ptx.read.ntid.x" ntid_decl e in

  e