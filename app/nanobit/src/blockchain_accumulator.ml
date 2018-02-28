open Core
open Async
open Nanobit_base

module Update = struct
  type t =
    | New_chain of Blockchain.t
end

let accumulate ~init ~parent_log ~prover ~updates ~strongest_chain =
  let log = Logger.child parent_log "blockchain_accumulator" in
  don't_wait_for begin
    let%map _last_block =
      Linear_pipe.fold updates ~init ~f:(fun chain (Update.New_chain new_chain) ->
        match%bind Prover.verify prover new_chain with
        | Error e ->
          Logger.error log "%s" (Error.to_string_hum (Error.tag e ~tag:"prover verify failed"));
          return chain
        | Ok false -> return chain
        | Ok true ->
          if Strength.(new_chain.state.strength > chain.Blockchain.state.strength)
          then begin
            let%map () = Pipe.write strongest_chain new_chain in
            new_chain
          end
          else
            return chain)
    in
    ()
  end
