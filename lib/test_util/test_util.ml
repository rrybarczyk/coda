open Core
open Snark_params
open Fold_lib

let triple_string trips =
  let to_string b = if b then "1" else "0" in
  String.concat ~sep:" "
    (List.map trips ~f:(fun (b1, b2, b3) ->
         to_string b1 ^ to_string b2 ^ to_string b3 ))

let checked_to_unchecked typ1 typ2 checked input =
  let open Tick in
  let (), checked_result =
    Tick.run_and_check
      (let open Let_syntax in
      let%bind input = provide_witness typ1 (As_prover.return input) in
      let%map result = checked input in
      As_prover.read typ2 result)
      ()
    |> Or_error.ok_exn
  in
  checked_result

let test_to_triples typ fold var_to_triples input =
  let open Tick in
  let (), checked =
    Tick.run_and_check
      (let open Let_syntax in
      let%bind input = provide_witness typ (As_prover.return input) in
      let%map result = var_to_triples input in
      As_prover.all
        (List.map result
           ~f:(As_prover.read (Typ.tuple3 Boolean.typ Boolean.typ Boolean.typ))))
      ()
    |> Or_error.ok_exn
  in
  let unchecked = Fold.to_list (fold input) in
  if not (checked = unchecked) then
    failwithf
      !"Got %s (%d)\nexpected %s (%d)"
      (triple_string checked) (List.length checked) (triple_string unchecked)
      (List.length unchecked) ()

let test_equal ?(equal= ( = )) typ1 typ2 checked unchecked input =
  let checked_result = checked_to_unchecked typ1 typ2 checked input in
  assert (equal checked_result (unchecked input))

let with_randomness r f =
  let s = Caml.Random.get_state () in
  Random.init r ;
  try
    let x = f () in
    Caml.Random.set_state s ; x
  with e -> Caml.Random.set_state s ; raise e