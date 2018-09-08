open Core
open Async
open Unix

module Rpcs = struct
  module Ping = struct
    type query = unit [@@deriving bin_io]

    type response = unit [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Ping" ~version:0 ~bin_query ~bin_response
  end

  module Run = struct
    type query = String.t * String.t list [@@deriving bin_io]

    type response = String.t [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Run" ~version:0 ~bin_query ~bin_response
  end

  module Setup_and_start = struct
    type cmd = String.t * String.t list [@@deriving bin_io]

    type query =
      { launch_cmd: cmd
      ; tar_string: String.t
      ; pre_cmds: cmd list
      ; post_cmds: cmd list }
    [@@deriving bin_io]

    type response = String.t [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Setup_and_start" ~version:0 ~bin_query
        ~bin_response
  end

  module Stop = struct
    type query = unit [@@deriving bin_io]

    type response = unit [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Stop" ~version:0 ~bin_query ~bin_response
  end

  module Start = struct
    type cmd = String.t * String.t list [@@deriving bin_io]

    type query = cmd [@@deriving bin_io]

    type response = unit [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Start" ~version:0 ~bin_query ~bin_response
  end
end

let run _ (prog, args) =
  let%map stdout = Process.run_exn ~prog ~args () in
  stdout

let ping _ () = return ()

let current_process = ref None

let stop _ () =
  let () =
    match !current_process with
    | None -> ()
    | Some process ->
        let pid = Process.pid process in
        ignore (Signal.send Signal.term (`Pid pid))
  in
  current_process := None ;
  Deferred.unit

let setup_and_start _
    {Rpcs.Setup_and_start.launch_cmd; tar_string; pre_cmds; post_cmds} =
  let%bind () = stop () () in
  let pre_cmds = List.concat [pre_cmds; [("bash", ["-c"; "rm -rf /app/*"])]] in
  let%bind pre_cmd_outs =
    Deferred.List.map ~how:`Sequential pre_cmds ~f:(fun (prog, args) ->
        Process.run ~prog ~args () )
  in
  let%bind tar =
    Process.create_exn ~working_dir:"/app" ~prog:"tar" ~args:["zxf"; "-"] ()
  in
  let tar_stdin = Process.stdin tar in
  Writer.write tar_stdin tar_string ;
  let%bind () = Writer.close tar_stdin in
  let%bind _res = Process.wait tar in
  let%bind post_cmd_outs =
    Deferred.List.map ~how:`Sequential post_cmds ~f:(fun (prog, args) ->
        Process.run ~prog ~args () )
  in
  let prog, args = launch_cmd in
  let%map process = Process.create_exn ~working_dir:"/app" ~prog ~args () in
  current_process := Some process ;
  let cmd_outs outs =
    List.map outs ~f:(function
      | Ok ss -> ss
      | Error e -> Core.Error.to_string_hum e )
  in
  String.concat ~sep:"\n"
    (List.concat [cmd_outs pre_cmd_outs; cmd_outs post_cmd_outs])

let start _ launch_cmd =
  let%bind () = stop () () in
  let prog, args = launch_cmd in
  let%map process = Process.create_exn ~working_dir:"/app" ~prog ~args () in
  current_process := Some process

let implementations =
  [ Rpc.Rpc.implement Rpcs.Run.rpc run
  ; Rpc.Rpc.implement Rpcs.Setup_and_start.rpc setup_and_start
  ; Rpc.Rpc.implement Rpcs.Stop.rpc stop
  ; Rpc.Rpc.implement Rpcs.Start.rpc start
  ; Rpc.Rpc.implement Rpcs.Ping.rpc ping ]

let implementations =
  Rpc.Implementations.create_exn ~implementations
    ~on_unknown_rpc:`Close_connection

;; Tcp.Server.create
     ~on_handler_error:
       (`Call (fun net exn -> eprintf "%s\n" (Exn.to_string_mach exn)))
     (Tcp.Where_to_listen.create ~socket_type:Socket.Type.tcp
        ~address:(`Inet (Unix.Inet_addr.of_string "127.0.0.1", 8100))
        ~listening_on:(fun x -> Fn.id))
     (fun address reader writer ->
       Rpc.Connection.server_with_close reader writer ~implementations
         ~connection_state:(fun _ -> ())
         ~on_handshake_error:`Ignore )

let () = never_returns (Scheduler.go ())