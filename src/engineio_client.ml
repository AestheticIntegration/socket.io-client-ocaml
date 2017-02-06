open Lwt.Infix

type ready_state =
  | Opening
  | Open
  | Closing
  | Closed

let string_of_ready_state = function
  | Opening -> "Opening"
  | Open -> "Open"
  | Closing -> "Closing"
  | Closed -> "Closed"

module Util = struct
  let const x _ = x
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

    let value ~default = function
      | Some x -> x
      | None -> default

    let value_map ~f ~default t =
      map ~f t |> value ~default

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

  type packet_data =
    | P_None
    | P_String of string
    | P_Binary of int list

  type t = packet_type * packet_data

  let string_of_packet_type : packet_type -> string =
    function
    | OPEN -> "open"
    | CLOSE -> "close"
    | PING -> "ping"
    | PONG -> "pong"
    | MESSAGE -> "message"
    | UPGRADE -> "upgrade"
    | NOOP -> "noop"
    | ERROR -> "error"

  let packet_type_of_int : int -> packet_type =
    function
    | 0 -> OPEN
    | 1 -> CLOSE
    | 2 -> PING
    | 3 -> PONG
    | 4 -> MESSAGE
    | 5 -> UPGRADE
    | 6 -> NOOP
    | _ -> ERROR

  let int_of_packet_type : packet_type -> int =
    function
    | OPEN -> 0
    | CLOSE -> 1
    | PING -> 2
    | PONG -> 3
    | MESSAGE -> 4
    | UPGRADE -> 5
    | NOOP -> 6
    | ERROR -> -1

  let string_of_packet_data : packet_data -> string =
    function
    | P_None -> ""
    | P_String data -> data
    | P_Binary data -> Stringext.of_list (List.map Char.chr data)

  let is_binary : packet_data -> bool =
    function
    | P_None -> false
    | P_String data -> false
    | P_Binary data -> true
end

module Parser = struct

  let protocol = 3

  (* See https://github.com/socketio/engine.io-protocol#encoding *)

  let decode_packet (is_string : bool) (codes : int list) : Packet.t =
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

  let decode_packet_string : string -> Packet.t =
    fun input ->
      input
      |> Stringext.to_list
      |> List.map Char.code
      |> decode_packet true

  let decode_packet_binary : string -> Packet.t =
    fun input ->
      input
      |> Stringext.to_list
      |> List.map Char.code
      |> decode_packet false

  let decode_payload_as_binary : string -> Packet.t list =
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

  let encode_packet : Packet.t -> string =
    fun (packet_type, packet_data) ->
      Printf.sprintf "%i%s"
        (Packet.int_of_packet_type packet_type)
        (Packet.string_of_packet_data packet_data)

  let encode_payload : Packet.t list -> string =
    fun packets ->
      let encode_one_packet (packet_type, packet_data) =
        let bin_flag =
          if Packet.is_binary packet_data then
            1
          else
            0
        in
        let data_as_string = Packet.string_of_packet_data packet_data in
        let payload_length =
          (* the length of the data plus one for the packet type *)
          1 + (String.length data_as_string)
        in
        let length_as_digits =
          (* convert the integer length of the packet_data to a byte string *)
          payload_length                (* 97 *)
          |> string_of_int              (* -> "97" *)
          |> Stringext.to_list          (* -> ['9'; '7']*)
          |> List.map Stringext.of_char (* -> ["9"; "7"] *)
          |> List.map int_of_string     (* -> [9; 7] *)
          |> List.map Char.chr          (* -> ['\t'; '\007'] *)
          |> Stringext.of_list          (* -> "\t\007" *)
        in
        Printf.sprintf "%c%s%c%i%s"
          (Char.chr bin_flag)
          length_as_digits
          (Char.chr 255)
          (Packet.int_of_packet_type packet_type)
          data_as_string
      in
      packets
      |> List.map encode_one_packet
      |> String.concat ""

  type handshake =
    { sid : string
    ; ping_interval : int
    ; ping_timeout : int
    ; upgrades : string list
    }

  let string_of_handshake handshake =
    Format.sprintf
      "sid: '%s' ping_interval: %i ping_timeout: %i"
      handshake.sid
      handshake.ping_interval
      handshake.ping_timeout

  let parse_handshake : Packet.packet_data -> handshake =
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
end

module Transport = struct
  module Polling = struct
    let section = Lwt_log.Section.make "transport.polling"

    type t =
      { ready_state : ready_state
      ; uri : Uri.t
      }

    let name = "polling"

    let create uri =
      { ready_state = Closed
      ; uri =
          Uri.add_query_param uri ("transport", [name])
      }

    let log_packet (packet_type, packet_data) =
      Lwt_log.debug_f ~section "decoded packet %s with data: '%s'"
        (Packet.string_of_packet_type packet_type |> String.uppercase_ascii)
        (match packet_data with
         | Packet.P_None -> "no data"
         | Packet.P_String string -> string
         | Packet.P_Binary codes -> Format.sprintf "binary packet_data of length %i" (List.length codes))

    let process_response : Cohttp_lwt_unix.Response.t * Cohttp_lwt_body.t -> Packet.t Lwt_stream.t Lwt.t =
      fun (resp, body) ->
        Lwt.(Cohttp.(Cohttp_lwt_unix.(
            let code =
              resp
              |> Response.status
              |> Code.code_of_status in
            Lwt_log.debug_f ~section "Received status code: %i" code >>= fun () ->
            if Code.is_success code then
              Cohttp_lwt_body.to_stream body
              |> Lwt_stream.map_list_s
                (fun line ->
                   Lwt_log.debug_f ~section "Got line:          '%s'" (String.escaped line) >>= fun () ->
                   let packets = Parser.decode_payload_as_binary line in
                   Lwt_list.iter_s log_packet packets >>= fun () ->
                   return packets)
              |> return
            else
              Cohttp_lwt_body.to_string body >>= fun body ->
              Lwt_log.error_f ~section "%s" body >>= fun () ->
              fail_with (Format.sprintf "bad response status: %i" code)
          )))

    let do_poll : t -> Packet.t Lwt_stream.t Lwt.t =
      fun t ->
        Lwt.(
          Cohttp.(Cohttp_lwt_unix.(
              Lwt_log.debug_f ~section "GET '%s'" (Uri.to_string t.uri) >>= fun () ->
              catch
                (fun () ->
                   Client.get
                     ~headers:(Header.init_with "accept" "application/json")
                     t.uri >>= process_response
                )
                (function
                  | Failure msg ->
                    Lwt_log.error_f ~section "Poll failed: '%s'" msg >>= fun () ->
                    return (Lwt_stream.of_list [])
                  | exn -> fail exn)
            ))
        )

    let write : t -> Packet.t list -> unit Lwt.t =
      fun t packets ->
        Lwt.(Cohttp.(Cohttp_lwt_unix.(
            let encoded_payload =
              Parser.encode_payload packets
            in
            Lwt_log.debug_f ~section "POST '%s' with data '%s'"
              (Uri.to_string t.uri)
              (encoded_payload |> String.escaped)
            >>= fun () ->
            catch
              (fun () ->
                 Client.post
                   ~headers:(Header.init_with "content-type" "application/octet-stream")
                   ~body:(encoded_payload |> Cohttp_lwt_body.of_string)
                   t.uri >>= fun (resp, body) ->
                 return_unit
              )
              (function
                | Failure msg ->
                  Lwt_log.error_f ~section "Write failed: '%s'" msg >>= fun () ->
                  return_unit
                | exn -> fail exn)
          )))

    let on_open t handshake =
      { ready_state = Open
      ; uri =
          t.uri
          |> (Util.flip Uri.remove_query_param) "sid"
          |> (Util.flip Uri.add_query_param) ("sid", [Parser.(handshake.sid)])
      }

    let on_close t =
      { ready_state = Closed
      ; uri =
          t.uri
          |> (Util.flip Uri.remove_query_param) "sid"
      }

    let close t =
      { t with
        ready_state = Closing
      }
  end

  (* TODO: allow different transports *)

  type t =
    | Polling of Polling.t

  let string_of_t = function
    | Polling _ -> "polling"

  let open' t =
    match t with
    | Polling polling ->
      Polling.open' polling >>= fun (polling, packets) ->
      Lwt.return (Polling polling, packets)

  let write t packets =
    match t with
    | Polling polling ->
      Polling.write polling packets

  let on_open t handshake =
    match t with
    | Polling polling ->
      Polling (Polling.on_open polling handshake)

  let on_close t =
    match t with
    | Polling polling ->
      Polling (Polling.on_close polling)

  let receive t =
    match t with
    | Polling polling ->
      Polling.do_poll polling

  let close t =
    match t with
    | Polling polling ->
      Polling (Polling.close polling)
end

module Socket = struct
  let section = Lwt_log.Section.make "socket"

  type t =
    { ready_state : ready_state
    ; transport : Transport.t
    ; handshake : Parser.handshake option
    ; ping_sent_at : float option
    ; pong_received_at : float option
    }

  let make_uri uri =
    Uri.with_query uri [("EIO", [string_of_int Parser.protocol])]

  let create uri =
    { ready_state = Opening
    ; transport =
        Transport.Polling (Transport.Polling.create (make_uri uri))
    ; handshake = None
    ; ping_sent_at = None
    ; pong_received_at = None
    }

  let write : t -> Packet.t list -> unit Lwt.t =
    fun socket packets ->
      match socket.ready_state, packets with
      | Closed, _
      | _, [] -> Lwt.return_unit
      | _, _ -> Transport.write socket.transport packets

  let on_open socket packet_data =
    let handshake = Parser.parse_handshake packet_data in
    Lwt_log.debug_f ~section "Got sid '%s'" Parser.(handshake.sid) >>= fun () ->
    let transport =
      Transport.on_open socket.transport handshake
    in
    let socket =
      { socket with
        ready_state = Open
      ; handshake = Some handshake
      ; transport = transport
      ; uri =
          Uri.add_query_param' socket.uri ("sid", Parser.(handshake.sid))
      }
    in
    Lwt.return socket

  let on_pong socket =
    let now = Unix.time () in
    Lwt_log.debug_f ~section "PONG received at %.2f" now >>= fun () ->
    Lwt.return
      { socket with
        pong_received_at = Some now
      }

  let on_close socket =
    let transport = Transport.on_close socket.transport in
    Lwt.return
      { socket with
        ready_state = Closed
      ; handshake = None
      ; transport = transport
      }

  let on_noop socket =
    (* TODO: On the polling transport, the server sends a NOOP after we send a
       CLOSE. Check that the same is true of the websocket transport (probably
       not). *)
    match socket.ready_state with
    | Closing -> on_close socket
    | _ -> Lwt.return socket

  let process_packet : t -> Packet.t -> t Lwt.t =
    fun socket (packet_type, packet_data) ->
      Lwt_log.debug_f ~section "process_packet %s"
        (packet_type
         |> Packet.string_of_packet_type
         |> String.uppercase_ascii) >>= fun () ->
      match packet_type with
      | Packet.OPEN -> on_open socket packet_data
      | Packet.PONG -> on_pong socket
      | Packet.CLOSE -> on_close socket
      | Packet.NOOP -> on_noop socket
      | _ -> Lwt.return socket

  let close : t -> Packet.t list * t =
    fun socket ->
      match socket.ready_state with
      | Closing
      | Closed -> ([], socket)
      | _ ->
        ( [(Packet.CLOSE, Packet.P_None)]
        , { socket with
            ready_state = Closing
          ; transport = Transport.close socket.transport
          }
        )

  let log_socket_state socket =
    Lwt_log.debug_f ~section "Socket: %s%s"
      (string_of_ready_state socket.ready_state)
      (Util.Option.value_map socket.handshake
         ~default:" (no handshake)"
         ~f:(fun handshake -> Format.sprintf " (%s)" (Parser.string_of_handshake handshake))) >>= fun () ->
    Lwt_log.debug_f ~section "Transport: %s"
      (string_of_ready_state
         (match socket.transport with
          | Transport.Polling polling ->
            Transport.Polling.(polling.ready_state)))

  let with_connection : 'a. Uri.t -> ((Packet.t Lwt_stream.t) -> (string -> unit Lwt.t) -> 'a Lwt.t) -> 'a Lwt.t =
    fun uri f ->
      (* packets to send via transport *)
      let (packets_send_stream, push_packet_send) = Lwt_stream.create () in
      (* packets received over transport *)
      let (packets_recv_stream, push_packet_recv) = Lwt_stream.create () in
      let send packet =
        push_packet_send (Some packet); Lwt.return_unit
      in
      let poll_once socket =
        Lwt_log.debug_f ~section "polling..." >>= fun () ->
        Transport.receive socket.transport >>= fun packets ->
        Lwt_stream.iter (fun packet -> push_packet_recv (Some packet)) packets
      in
      let maybe_poll_again poll_promise socket =
        match socket.ready_state, Lwt.is_sleeping poll_promise with
        | Closed, _ (* socket closed, don't renew *)
        | _, true -> poll_promise (* still polling, don't renew *)
        | _ -> poll_once socket (* poll again *)
      in
      let sleep_until_ping socket handshake =
        match socket.ping_sent_at, socket.pong_received_at with
        | None, _ ->
          Lwt_log.debug ~section "no ping_sent_at: send ping now"
        | Some ping_sent_at, None ->
          (* We are waiting for PONG from server. Raise Timeout if we
             don't get it in time. *)
          let seconds_since_last_ping =
            Unix.time () -. ping_sent_at in
          let ping_timeout_seconds =
            (float_of_int Parser.(handshake.ping_timeout)) /. 1000.0 in
          let timeout_seconds =
            ping_timeout_seconds -. seconds_since_last_ping in
          Lwt_log.debug_f ~section "Waiting %.2f seconds for PONG" timeout_seconds >>= fun () ->
          Lwt_unix.timeout timeout_seconds
        | _, Some pong_received_at ->
          (* All good, send a PING at the next interval. *)
          let seconds_since_last_pong =
            Unix.time () -. pong_received_at in
          let ping_interval_seconds =
            (float_of_int Parser.(handshake.ping_interval)) /. 1000.0 in
          let sleep_seconds =
            ping_interval_seconds -. seconds_since_last_pong in
          Lwt_log.debug_f ~section "Will ping in %.2f seconds" sleep_seconds >>= fun () ->
          Lwt_unix.sleep sleep_seconds >>= fun () ->
          Lwt_log.debug ~section "Waking to send ping"
      in
      let maybe_send_ping socket =
        let should_ping =
          match socket.ready_state, socket.handshake with
          | Closing, _
          | Closed, _ -> false
          | _, None -> false (* Not connected. *)
          | _, Some handshake ->
            (match socket.ping_sent_at, socket.pong_received_at with
             | None, _ -> true (* No ping sent yet. *)
             | Some _, None -> false (* Ping sent, waiting for pong. *)
             | _, Some pong_received_at ->
               let seconds_since_last_pong = Unix.time () -. pong_received_at in
               let ping_interval_seconds = (float_of_int Parser.(handshake.ping_interval)) /. 1000.0 in
               seconds_since_last_pong >= ping_interval_seconds)
        in
        if should_ping then
          send (Packet.PING, Packet.P_None) >>= fun () ->
          Lwt.return
            { socket with
              ping_sent_at = Some (Unix.time ())
            ; pong_received_at = None
            }
        else
          Lwt.return socket
      in
      let sleep_until_packet_received () =
        Lwt_stream.peek packets_recv_stream >>= fun _ ->
        Lwt_log.debug ~section "Waking to process a packet"
      in
      let sleep_until_packet_to_send () =
        Lwt_stream.peek packets_send_stream >>= fun _ ->
        Lwt_log.debug ~section "Waking to send a packet"
      in
      let maybe_close socket user_promise =
        if Lwt.is_sleeping user_promise then
          Lwt.return socket
        else
          (* User thread has finished; close the socket *)
          Lwt_log.debug ~section "User thread has finished; closing the socket." >>= fun () ->
          let packets, socket = close socket in
          Lwt_list.iter_s send packets >>= fun () ->
          Lwt.return socket
      in
      let rec maintain_connection : 'a. unit Lwt.t -> 'a Lwt.t -> t -> 'a Lwt.t =
        (* TODO: handle user thread finishing before open *)
        fun poll_promise user_promise socket ->
          log_socket_state socket >>= fun () ->
          let poll_promise = maybe_poll_again poll_promise socket in
          let sleep_promise =
            Lwt.pick
              (List.concat
                 [ (* If we're connected, wake up for pings. *)
                   socket.handshake
                   |> Util.Option.map ~f:(sleep_until_ping socket)
                   |> Util.Option.to_list
                 ; [ sleep_until_packet_received ()
                   ; sleep_until_packet_to_send ()
                   ]
                 ])
          in
          Lwt.choose
            (List.concat
               [ if Lwt.is_sleeping user_promise then [user_promise >>= fun _ -> Lwt.return_unit] else []
               ; [ poll_promise
                 ; sleep_promise
                 ]
               ]) >>= fun () ->
          let () = Lwt.cancel sleep_promise in
          Lwt_list.fold_left_s
            process_packet
            socket
            (Lwt_stream.get_available packets_recv_stream) >>= fun socket ->
          maybe_close socket user_promise >>= fun socket ->
          maybe_send_ping socket >>= fun socket ->
          write socket (Lwt_stream.get_available packets_send_stream) >>= fun () ->
          match socket.ready_state with
          | Closed ->
            Lwt_log.debug ~section "Socket is Closed, now waiting for user promise to terminate." >>= fun () ->
            user_promise
          | _ -> maintain_connection poll_promise user_promise socket
      in
      let socket = create uri in
      let poll_promise = poll_once socket in
      let user_promise =
        f (Lwt_stream.clone packets_recv_stream)
          (fun data -> send (Packet.MESSAGE, Packet.P_String data))
      in
      maintain_connection poll_promise user_promise socket
end
