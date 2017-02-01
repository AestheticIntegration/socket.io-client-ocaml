type ready_state =
  | Opening
  | Open
  | Closing
  | Closed

module Util = struct
  let flip f a b = f b a

  module List = struct
    let split_at index list =
      if index <= 0 then
        ([], list)
      else
        let rec loop i t accum =
          if i = 0 then
            (List.rev accum, t)
          else
            match t with
            | [] -> (list, [])
            | hd :: tl -> loop (i - 1) tl (hd :: accum)
        in
        loop index list []
  end

  module Option = struct
    let map ~f = function
      | Some x -> Some (f x)
      | None -> None

    let to_list = function
      | Some x -> [x]
      | None -> []
  end
end

module Packet = struct
  type packet_type =
    | OPEN
    | CLOSE
    | PING
    | PONG
    | MESSAGE
    | UPGRADE
    | NOOP
    | ERROR

  type payload =
    | P_None
    | P_String of string
    | P_Binary of int list

  type t = packet_type * payload

  let string_of_packet_type = function
    | OPEN -> "open"
    | CLOSE -> "close"
    | PING -> "ping"
    | PONG -> "pong"
    | MESSAGE -> "message"
    | UPGRADE -> "upgrade"
    | NOOP -> "noop"
    | ERROR -> "error"

  let packet_type_of_int = function
    | 0 -> OPEN
    | 1 -> CLOSE
    | 2 -> PING
    | 3 -> PONG
    | 4 -> MESSAGE
    | 5 -> UPGRADE
    | 6 -> NOOP
    | _ -> ERROR

  let int_of_packet_type = function
    | OPEN -> 0
    | CLOSE -> 1
    | PING -> 2
    | PONG -> 3
    | MESSAGE -> 4
    | UPGRADE -> 5
    | NOOP -> 6
    | ERROR -> -1
end

module Parser = struct

  let protocol = 3

  let decode_packet (is_string : bool) (codes : int list) : (Packet.packet_type * Packet.payload) =
    match codes with
    | i :: rest ->
      ( i |> Char.chr |> Stringext.of_char |> int_of_string |> Packet.packet_type_of_int
      , if is_string then
          Packet.P_String
            (List.map Char.chr rest
             |> Stringext.of_list)
        else
          Packet.P_Binary rest
      )
    | [] ->
      (Packet.ERROR, Packet.P_String "Empty packet")

  let decode_payload_as_binary : string -> (Packet.packet_type * Packet.payload) list =
    fun string ->
      let decode_payload is_string payload_length codes =
        let (this_packet_data, codes) = Util.List.split_at payload_length codes in
        ( decode_packet is_string this_packet_data
        , codes
        )
      in
      let rec decode_payload_length is_string length = function
        | 255 :: codes ->
          let payload_length =
            length
            |> List.rev_map string_of_int
            |> String.concat ""
            |> int_of_string in
          decode_payload is_string payload_length codes
        | c :: codes -> decode_payload_length is_string (c :: length) codes
        | [] -> raise (Invalid_argument "No payload length")
      in
      let decode_one_packet = function
        | 0 :: codes -> decode_payload_length true [] codes
        | 1 :: codes -> decode_payload_length false [] codes
        | c :: _ -> raise (Invalid_argument (Format.sprintf "Invalid string/binary flag: %i" c))
        | [] -> raise (Invalid_argument "Empty payload")
      in
      let rec go codes =
        match decode_one_packet codes with
        | (packet, []) -> [packet]
        | (packet, codes) -> packet :: go codes
      in
      let char_codes = Stringext.to_list string |> List.map Char.code in
      go char_codes

  let encode_packet : (Packet.packet_type * Packet.payload) -> string =
    fun (packet_type, payload) ->
      let (bin_flag, data_length, data_as_string) =
        match payload with
        | Packet.P_None -> (0, 0, "")
        | Packet.P_String data -> (0, String.length data, data)
        | Packet.P_Binary data -> (1, List.length data, (Stringext.of_list (List.map Char.chr data)))
      in
      let payload_length =
        (* the length of the data plus one for the packet type *)
        1 + data_length
      in
      let length_as_digits =
        (* convert the integer length of the payload to a byte string *)
        payload_length                (* 97 *)
        |> string_of_int              (* -> "97" *)
        |> Stringext.to_list          (* -> ['9'; '7']*)
        |> List.map Stringext.of_char (* -> ["9"; "7"] *)
        |> List.map int_of_string     (* -> [9; 7] *)
        |> List.map Char.chr          (* -> ['\t'; '\007'] *)
        |> Stringext.of_list          (* -> "\t\007" *)
      in
      String.concat ""
        [ Stringext.of_char (Char.chr bin_flag)
        ; length_as_digits
        ; Stringext.of_char (Char.chr 255)
        ; string_of_int (Packet.int_of_packet_type packet_type)
        ; data_as_string
        ]
end


module Transport = struct
  module Polling = struct
    type t =
      { ready_state : ready_state
      ; polling : bool
      ; writeable : bool
      ; uri : Uri.t
      }

    let name = "polling"

    let create uri =
      { ready_state = Closed
      ; polling = false
      ; writeable = false
      ; uri =
          Uri.add_query_param uri ("transport", [name])
      }

    let log_packet (packet_type, packet_data) =
      Lwt.(
        Lwt_io.printlf "decoded packet: %s data: '%s'"
          (Packet.string_of_packet_type packet_type)
          (match packet_data with
           | Packet.P_None -> "no data"
           | Packet.P_String string -> string
           | Packet.P_Binary codes -> Format.sprintf "binary packet_data of length %i" (List.length codes))
      )

    let process_packet : t -> Packet.t -> t =
      fun t (packet_type, packet_data) ->
        let t =
          match t.ready_state with
          | Opening -> { t with
                         ready_state = Open
                       ; writeable = true
                       }
          | _ -> t
        in
        match packet_type with
        | Packet.CLOSE -> { t with ready_state = Closed }
        | _ -> t

    let process_response : Cohttp_lwt_unix.Response.t * Cohttp_lwt_body.t -> Packet.t Lwt_stream.t Lwt.t =
      fun (resp, body) ->
      Lwt.(Cohttp.(Cohttp_lwt_unix.(
          let code =
            resp
            |> Response.status
            |> Code.code_of_status in
          (* Lwt_io.printlf "Received status code: %i" code >>= fun () -> *)
          if Code.is_success code then
            Cohttp_lwt_body.to_stream body
            |> Lwt_stream.map_list_s
              (fun line ->
                 (* Lwt_io.printlf "Got line:          '%s'" (String.escaped line) >>= fun () -> *)
                 let packets = Parser.decode_payload_as_binary line in
                 Lwt_list.iter_s log_packet packets >>= fun () ->
                 return packets)
            |> return
          else
            Cohttp_lwt_body.to_string body >>= fun body ->
            Lwt_io.printl body >>= fun () ->
            fail_with (Format.sprintf "bad response status: %i" code)
        )))

    let do_poll : t -> Packet.t Lwt_stream.t Lwt.t =
      fun t ->
        Lwt.(
          let t = { t with polling = true } in
          Cohttp.(Cohttp_lwt_unix.(
              Lwt_io.printlf "Sending GET request %s" (Uri.to_string t.uri) >>= fun () ->
              Client.get
                ~headers:(Header.init_with "accept" "application/json")
                t.uri >>= process_response
            ))
        )

    let write : t -> Packet.t list -> unit Lwt.t =
      fun t packets ->
        Lwt.(
          match packets with
          | [] -> return_unit
          | _ ->
            Cohttp.(Cohttp_lwt_unix.(
                let encoded_payload =
                  packets
                  |> List.map Parser.encode_packet
                  |> String.concat ""
                in
                Lwt_io.printlf "Sending POST request to '%s' with data '%s'"
                  (Uri.to_string t.uri)
                  (encoded_payload |> String.escaped)
                >>= fun () ->
                let body =
                  encoded_payload
                  |> Cohttp_lwt_body.of_string
                in
                catch
                  (fun () ->
                     Client.post
                       ~headers:(Header.init_with "content-type" "application/octet-stream")
                       ~body:body
                       t.uri >>= fun (resp, body) ->
                     return_unit)
                  (fun exn ->
                     match exn with
                     | Failure "Client connection was closed" -> return_unit
                     | exn -> fail exn
                  )
              ))
        )

    let open' : t -> (t * Packet.t Lwt_stream.t) Lwt.t =
      fun t ->
        Lwt.(
          match t.ready_state with
          | Closed ->
            let t =
              { t with
                ready_state = Opening
              }
            in
            do_poll t >>= fun packets ->
            return (t, packets)
          | _ ->
            Lwt.fail_with "open: transport is not Closed"
        )

    let close t push_packet =
      match t.ready_state with
      | Opening
      | Open ->
        let t =
          { t with
            ready_state = Closed
          }
        in
        Lwt.(
          write t [(Packet.CLOSE, Packet.P_None)] >>= fun _ -> return t
        )
      | _ ->
        Lwt.return t
  end

  (* TODO: allow different transports *)

  type t = Polling.t
  (* | Polling of Polling.t *)


  (* let string_of_t = function *)
  (*   | Polling _ -> "polling" *)
  let string_of_t _ = "polling"
end

module Socket = struct
  type handshake =
    { sid : string
    ; ping_interval : int
    ; ping_timeout : int
    ; upgrades : string list
    }

  type t =
    { ready_state : ready_state
    ; transport : Transport.t
    ; handshake : handshake option
    ; ping_sent_at : float option
    ; pong_received_at : float option
    }

  let make_uri uri =
    Uri.with_query uri [("EIO", [string_of_int Parser.protocol])]

  let parse_handshake : Packet.payload -> handshake =
    fun packet_data ->
      match packet_data with
      | Packet.P_None -> raise (Invalid_argument "no data")
      | Packet.P_Binary _ -> raise (Invalid_argument "binary")
      | Packet.P_String string ->
        Yojson.Basic.(
          match from_string string with
          | `Assoc assoc ->
            let sid =
              match List.assoc "sid" assoc with
              | `String sid -> sid
              | _ -> raise (Invalid_argument "expected sid to be a string")
            in
            let upgrades =
              match List.assoc "upgrades" assoc with
              | `List ls ->
                ls
                |> List.map (function
                    | `String upgrade -> upgrade
                    | _ -> raise (Invalid_argument "expected upgrade to be a string")
                  )
              | _ -> raise (Invalid_argument "expected upgrades to be a list")
            in
            let ping_interval =
              match List.assoc "pingInterval" assoc with
              | `Int interval -> interval
              | _ -> raise (Invalid_argument "expected pingInterval to be an int")
            in
            let ping_timeout =
              match List.assoc "pingTimeout" assoc with
              | `Int timeout -> timeout
              | _ -> raise (Invalid_argument "expected pingTimeout to be an int")
            in
            { sid = sid
            ; ping_interval = ping_interval
            ; ping_timeout = ping_timeout
            ; upgrades = upgrades
            }
          | _ -> raise (Invalid_argument "expected an object")
        )

  let open' : Uri.t -> (t * Packet.t Lwt_stream.t) Lwt.t =
    fun uri ->
      let transport =
        Transport.Polling.create (make_uri uri) in
      let socket =
        { ready_state = Opening
        ; transport = transport
        ; handshake = None
        ; ping_sent_at = None
        ; pong_received_at = None
        }
      in
      Lwt.(
        Transport.Polling.open' transport >>= fun (transport, packets) ->
        return ({ socket with transport = transport }, packets)
      )

  let write : t -> Packet.t list -> unit Lwt.t =
    fun socket packets ->
      Transport.Polling.write socket.transport packets

  let on_open socket packet_data =
    Lwt.(
      let handshake = parse_handshake packet_data in
      Lwt_io.printlf "Got sid '%s'" handshake.sid >>= fun () ->
      let transport =
        Transport.Polling.{ socket.transport with
                            uri =
                              socket.transport.uri
                              |> (Util.flip Uri.remove_query_param) "sid"
                              |> (Util.flip Uri.add_query_param) ("sid", [handshake.sid])
                          }
      in
      return { socket with
               handshake = Some handshake
             ; transport = transport
             }
    )

  let on_pong socket =
    Lwt.(
      return { socket with
               pong_received_at = Some (Unix.time ())
             }
    )

  let process_packet : t -> Packet.t -> t Lwt.t =
    fun socket (packet_type, packet_data) ->
      Lwt.(
        match packet_type with
        | Packet.OPEN -> on_open socket packet_data
        | Packet.PONG -> on_pong socket
        | _ -> return socket
      )

  let poll_interval = 2.0

  let with_connection :  Uri.t -> ((Packet.t Lwt_stream.t) -> (Packet.t -> unit Lwt.t) -> 'a Lwt.t) -> 'a Lwt.t =
    fun uri f ->
      (* packets to send via transport *)
      let (packets_send_stream, push_packet_send) = Lwt_stream.create () in
      (* packets received over transport *)
      let (packets_recv_stream, push_packet_recv) = Lwt_stream.create () in
      let send packet =
        push_packet_send (Some packet); Lwt.return_unit
      in
      Lwt.(
        let open_conn () =
          open' uri >>= fun (socket, packets) ->
          Lwt_stream.fold_s
            (fun packet socket ->
               push_packet_recv (Some packet);
               process_packet socket packet)
            packets socket
            (* TODO: check we got an sid in the first set of packets. *)
            (* TODO: we are processing these packets twice. *)
        in
        let rec poll_forever socket =
          Lwt_io.printl "polling..." >>= fun () ->
          Transport.Polling.do_poll socket.transport >>= fun packets ->
          Lwt_stream.iter (fun packet -> push_packet_recv (Some packet)) packets >>= fun () ->
          poll_forever socket
        in
        let rec maintain_connection socket  =
          match socket.handshake with
          | None -> Lwt.fail_with "maintain_connection: socket not open"
          | Some handshake ->
            (
             let sleep_until_ping () =
               let return_ping () =
                 push_packet_send (Some (Packet.PING, Packet.P_None));
                 Lwt.return
                   { socket with
                     ping_sent_at = Some (Unix.time ())
                   }
               in
               match socket.ping_sent_at with
               | None ->
                 Lwt_io.printl "no ping_sent_at: send ping now" >>= fun () ->
                 return_ping ()
               | Some ping_sent_at ->
                 let timeout_on_pong () =
                   let seconds_since_last_ping = Unix.time () -. ping_sent_at in
                   let ping_timeout_seconds = (float_of_int handshake.ping_timeout) /. 1000.0 in
                   Lwt_unix.timeout (ping_timeout_seconds -. seconds_since_last_ping)
                 in
                 (match socket.pong_received_at with
                  | None ->
                    (* We are waiting for PONG from server *)
                    timeout_on_pong ()
                  | Some pong_received_at when ping_sent_at > pong_received_at ->
                    (* We are waiting for PONG from server *)
                    timeout_on_pong ()
                  | Some pong_received_at ->
                    (* All good, send a PING at the next interval. *)
                    let seconds_since_last_pong = Unix.time () -. pong_received_at in
                    let ping_interval_seconds = (float_of_int handshake.ping_interval) /. 1000.0 in
                    Lwt_unix.sleep (ping_interval_seconds -. seconds_since_last_pong) >>= fun () ->
                    Lwt_io.printl "sleep_until_ping" >>= fun () ->
                    return_ping ()
                 )
             in
             let sleep_until_packet_to_send () =
               Lwt_stream.peek packets_send_stream >>= fun _ ->
               Lwt_io.printl "sleep_until_packet_to_send" >>= fun () ->
               return socket
             in
             let sleep_until_packet_received () =
               Lwt_stream.peek packets_recv_stream >>= fun _ ->
               Lwt_io.printl "sleep_until_packet_received" >>= fun () ->
               return socket
             in
             pick
               (* TODO: how to ensure none of these are dropped if >1 returns at once? *)
               [ sleep_until_ping ()
               ; sleep_until_packet_to_send ()
               ; sleep_until_packet_received ()
               ]
             >>= fun socket ->
             (* TODO: how do we propagate updates to the socket state to the poll_forever thread? *)
             Lwt_list.fold_left_s process_packet socket (Lwt_stream.get_available packets_recv_stream) >>= fun socket ->
             write socket (Lwt_stream.get_available packets_send_stream) >>= fun () ->
             return socket)
            >>= maintain_connection
        in
        open_conn () >>= fun socket ->
        pick
          [ poll_forever socket
          ; maintain_connection socket
          ; f (Lwt_stream.clone packets_recv_stream) send
          ]
      )
end

let main () =
  Lwt_main.run
    Lwt.(
      Lwt_io.printl "running..." >>= fun () ->
      let uri =
        Uri.make
          ~scheme:"http"
          ~host:"localhost"
          (* ~port:3000 *)
          (* ~path:"socket.io/" *)
          ~port:3001
          ~path:"engine.io/"
          ()
      in
      Socket.with_connection uri
        (fun packets send_packet ->
           let react = function
             | Some (packet_type, _) ->
               Lwt_io.printlf "-- User got a packet '%s'!"
                 (Packet.string_of_packet_type packet_type)
             | None ->
               Lwt_io.printl "End of packet stream?" >>= fun () ->
               Lwt.fail Exit
           in
           let rec react_forever () = Lwt_stream.get packets >>= react >>= react_forever
           in
           let rec sendline () =
             Lwt_io.(read_line_opt stdin) >>= function
             | None ->
               Lwt.return_unit
             | Some content ->
               send_packet (Packet.MESSAGE, Packet.P_String content) >>= sendline
           in
           sendline () <?> react_forever ())
    )
