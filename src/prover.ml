open Term
open Pprint
open Lppterm
open Printf

type top_command =
  | Theorem of id * lppterm

type command =
  | Induction of int list
  | Apply of id * id list
  | Inst of id * term
  | Case of id
  | Search
  | Intros
  | Undo

type id = string

type vars = (id * term) list
type hyps = (id * lppterm) list
type lemmas = (id * lppterm) list

type subgoal = unit -> unit

let vars : vars ref = ref []
let hyps : hyps ref = ref []
let goal : lppterm ref = ref (obj (const "placeholder"))
let subgoals : subgoal list ref = ref []
let lemmas : lemmas ref = ref []

let var_names () =
  List.map fst !vars

let count = ref 0

let fresh_hyp_name () =
  incr count ;
  "H" ^ (string_of_int !count)
  
type clauses = (lppterm * lppterm list) list
  
let clauses : clauses ref = ref []

let reset_prover () =
  count := 0 ;
  vars := [] ;
  hyps := [] ;
  goal := obj (const "placeholder") ;
  subgoals := []


let undo_stack = ref []
  
let save_undo_state () =
  undo_stack := (!count, !vars, !hyps, !goal, !subgoals, Term.save_state ())::
    !undo_stack
    
let undo () =
  match !undo_stack with
    | (saved_count, saved_vars, saved_hyps, saved_goal, saved_subgoals,
       saved_term_state)::rest ->
        count := saved_count ;
        vars := saved_vars ;
        hyps := saved_hyps ;
        goal := saved_goal ;
        subgoals := saved_subgoals ;
        Term.restore_state saved_term_state ;
        undo_stack := rest
    | [] -> failwith "Nothing left to undo"
          
  
let add_hyp ?(name=fresh_hyp_name ()) term =
  hyps := List.append !hyps [(name, term)]

let add_var v =
  vars := List.append !vars [v]

let add_if_new_var (name, v) =
  if not (List.mem name (var_names ())) then add_var (name, v)

let add_lemma name lemma =
  lemmas := (name, lemma)::!lemmas

let get_hyp name =
  List.assoc name !hyps

let get_lemma name =
  List.assoc name !lemmas

let get_hyp_or_lemma name =
  if List.mem_assoc name !hyps then
    get_hyp name
  else
    get_lemma name

let next_subgoal () =
  match !subgoals with
    | [] -> failwith "Proof completed."
    | set_subgoal::rest ->
        set_subgoal () ;
        subgoals := rest

let vars_to_string vars =
  match vars with
    | [] -> ""
    | _ -> "  Variables: " ^ (String.concat ", " (var_names ()))

let hyps_to_string hyps =
  String.concat "\n"
    (List.map (fun (id, t) -> "  " ^ id ^ " : " ^ (lppterm_to_string t)) hyps)
   
let div = "  ============================"

let get_display () =
  let buffer = Buffer.create 100 in
    bprintf buffer "%d subgoal(s).\n" (1 + List.length !subgoals) ;
    bprintf buffer "\n" ;
    bprintf buffer "%s\n" (vars_to_string !vars) ;
    bprintf buffer "%s\n" (hyps_to_string !hyps) ;
    bprintf buffer "%s\n" div ;
    bprintf buffer "  %s\n" (lppterm_to_string !goal) ;
    bprintf buffer "\n" ;
    Buffer.contents buffer
    
let display () =
  print_string (get_display ())

(* Inst *)

let inst h t =
  save_undo_state () ;
  let stmt = get_hyp h in
    if Tactics.is_pi_abs (obj_to_term stmt) then
      add_hyp (Tactics.object_inst stmt (Tactics.replace_term_vars !vars t))
    else
      failwith ("Hypothesis must have the form {pi x\\ ...} " ^
                  "in order to instantiate it with a term.")

(* Apply *)
          
let apply h args =
  save_undo_state () ;
  let stmt = get_hyp_or_lemma h in
    add_hyp
      begin match stmt, args with
        | Forall _, _ ->
            Tactics.apply_forall stmt (List.map get_hyp args)
        | Obj(t, _), [arg] when Tactics.is_imp t ->
            Tactics.object_cut stmt (get_hyp arg)
        | _ -> failwith "Bad application"
      end

(* Case *)

let set_minus lst1 lst2 =
  List.filter (fun x -> not (List.mem x lst2)) lst1

let add_cases_to_subgoals cases =
  let case_to_subgoal (set_state, used_vars, new_hyps) =
    let saved_vars = !vars in
    let saved_hyps = !hyps in
    let saved_goal = !goal in
    let saved_count = !count in
      fun () ->
        vars := saved_vars ;
        hyps := saved_hyps ;
        goal := saved_goal ;
        count := saved_count ;
        List.iter add_if_new_var used_vars ;
        List.iter add_hyp new_hyps ;
        set_state () ;
  in
    subgoals := List.append (List.map case_to_subgoal cases) !subgoals
      
let case str =
  save_undo_state () ;
  let obj = get_hyp str in
  let cases = Tactics.case obj !clauses (List.map fst !vars) in
    match cases with
      | [] -> next_subgoal ()
      | (set_state, used_vars, new_hyps)::other_cases ->
          add_cases_to_subgoals other_cases ;
          List.iter add_if_new_var used_vars ;
          set_state () ;
          List.iter add_hyp new_hyps

(* Induction *)
            
let induction args =
  save_undo_state () ;
  let (ih, new_goal) = Tactics.induction args !goal in
    add_hyp ~name:"IH" ih ;
    goal := new_goal

(* Search *)

let search () =
  save_undo_state () ;
  if Tactics.search 5 !goal !clauses (var_names ()) (List.map snd !hyps) then
    next_subgoal ()
  else
    ()

(* Theorem *)

let theorem thm =
  goal := thm

(* Intros *)

let rec split_args stmt =
  match stmt with
    | Arrow(left, right) ->
        let args, goal = split_args right in
          (left::args, goal)
    | Obj _ -> ([], stmt)
    | Forall _ -> failwith "Forall found in split_args"

let intros () =
  save_undo_state () ;
  if !vars != [] then
    failwith "Intros can only be used when there are no context variables" ;
  match !goal with
    | Forall(bindings, body) ->
        vars := Tactics.fresh_alist_wrt Eigen bindings [] ;
        let fresh_body = Tactics.replace_lppterm_vars !vars body in
        let args, new_goal = split_args fresh_body in
          List.iter add_hyp args ;
          goal := new_goal
    | _ ->
        let args, new_goal = split_args !goal in
          List.iter add_hyp args ;
          goal := new_goal
