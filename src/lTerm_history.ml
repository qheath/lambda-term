(*
 * lTerm_history.ml
 * ----------------
 * Copyright : (c) 2012, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of Lambda-Term.
 *)

open CamomileLibraryDyn.Camomile
open Lwt

(* A node contains an entry of the history. *)
type node = {
  mutable data : Zed_utf8.t;
  mutable size : int;
  mutable prev : node;
}

type t = {
  mutable entries : node;
  (* Points to the first entry (the most recent). Its [prev] is a fake
     node used as marker, is after the oldest entry. *)
  mutable full_size : int;
  mutable length : int;
  mutable max_size : int;
  mutable max_entries : int;
  mutable old_count : int;
  mutable cache : Zed_utf8.t list option;
  (* When set, the cache is equal to the list of entries, from the
     most recent to the oldest. *)
}

let entry_size str =
  let size = ref 0 in
  for i = 0 to String.length str - 1 do
    match String.unsafe_get str i with
      | '\n' | '\\' ->
          size := !size + 2
      | _ ->
          size := !size + 1
  done;
  !size + 1

(* Check that [size1 + size2 < limit], handling overflow. *)
let size_ok size1 size2 limit =
  let sum = size1 + size2 in
  sum >= 0 && sum <= limit

let create ?(max_size=max_int) ?(max_entries=max_int) init =
  if max_size < 0 then
    invalid_arg "LTerm_history.create: negative maximum size";
  if max_entries < 0 then
    invalid_arg "LTerm_history.create: negative maximum number of entries";
  let rec aux size count node entries =
    match entries with
      | [] ->
          (size, count, node)
      | entry :: entries ->
          let entry_size = entry_size entry in
          if size_ok size entry_size max_size && count + 1 < max_entries then begin
            let next = { data = ""; prev = node; size = 0 } in
            node.data <- entry;
            node.size <- entry_size;
            aux (size + entry_size) (count + 1) next entries
          end else
            (size, count, node)
  in
  let rec node = { data = ""; size = 0; prev = node } in
  let size, count, marker = aux 0 0 node init in
  node.prev <- marker;
  {
    entries = node;
    full_size = size;
    length = count;
    max_size = max_size;
    max_entries = max_entries;
    old_count = count;
    cache = None;
  }

let spaces = UCharInfo.load_property_tbl `White_Space

let is_space ch = UCharTbl.Bool.get spaces ch
let is_empty str = Zed_utf8.for_all is_space str

let is_dup history entry =
  history.length > 0 && history.entries.data = entry

(* Remove the oldest entry of history, precondition: the history
   contains at least one entry. *)
let drop_oldest history =
  let last = history.entries.prev.prev in
  (* Make [last] become the end of entries marker. *)
  history.entries.prev <- last;
  (* Update counters. *)
  history.length <- history.length - 1;
  history.full_size <- history.full_size - last.size;
  if history.old_count > 0 then history.old_count <- history.old_count - 1;
  (* Clear the marker so its contents can be garbage collected. *)
  last.data <- "";
  last.size <- 0

let add_aux history data size =
  if size <= history.max_size then begin
    (* Check length. *)
    if history.length = history.max_entries then begin
      history.cache <- None;
      (* We know that [max_entries > 0], so the precondition is
         verified. *)
      drop_oldest history
    end;
    (* Check size. *)
    if not (size_ok history.full_size size history.max_size) then begin
      history.cache <- None;
      (* We know that size <= max_size, so we are here only if there
         is at least one other entry in the history, so the
         precondition is verified. *)
      drop_oldest history;
      while not (size_ok history.full_size size history.max_size) do
        (* Same here. *)
        drop_oldest history
      done
    end;
    (* Add the entry. *)
    let node = { data = data; size = size; prev = history.entries.prev } in
    history.entries.prev <- node;
    history.entries <- node;
    history.length <- history.length + 1;
    history.full_size <- history.full_size + size;
    match history.cache with
      | None ->
          ()
      | Some l ->
          history.cache <- Some (data :: l)
  end

let add history ?(skip_empty=true) ?(skip_dup=true) entry =
  if history.max_entries > 0 && history.max_size > 0 && not (skip_empty && is_empty entry) && not (skip_dup && is_dup history entry) then
    add_aux history entry (entry_size entry)

let rec list_of_nodes marker acc node =
  if node == marker then
    acc
  else
    list_of_nodes marker (node.data :: acc) node.prev

let contents history =
  match history.cache with
    | Some l ->
        l
    | None ->
        let marker = history.entries.prev in
        let l = list_of_nodes marker [] marker.prev in
        history.cache <- Some l;
        l

let size history = history.full_size
let length history = history.length
let old_count history = history.old_count
let max_size history = history.max_size
let max_entries history = history.max_entries

let set_old_count history n =
  if n < 0 then
    invalid_arg "LTerm_history.set_old_count: negative old count";
  if n > history.length then
    invalid_arg "LTerm_history.set_old_count: old count greater than the length of the history";
  history.old_count <- n

let set_max_size history size =
  if size < 0 then
    invalid_arg "LTerm_history.set_max_size: negative maximum size";
  if size < history.full_size then begin
    history.cache <- None;
    (* 0 <= size < full_size so there is at least one element. *)
    drop_oldest history;
    while size < history.full_size do
      (* Same here. *)
      drop_oldest history
    done
  end;
  history.max_size <- size

let set_max_entries history n =
  if n < 0 then
    invalid_arg "LTerm_history.set_max_entries: negative maximum number of entries";
  if n < history.length then begin
    history.cache <- None;
    (* 0 <= n < length so there is at least one element. *)
    drop_oldest history;
    while n < history.length do
      (* Same here. *)
      drop_oldest history
    done
  end;
  history.max_entries <- n

let escape entry =
  let len = String.length entry in
  let buf = Buffer.create len in
  let rec loop ofs =
    if ofs = len then
      Buffer.contents buf
    else
      match String.unsafe_get entry ofs with
        | '\n' ->
            Buffer.add_string buf "\\n";
            loop (ofs + 1)
        | '\\' ->
            Buffer.add_string buf "\\\\";
            loop (ofs + 1)
        | ch when Char.code ch <= 127 ->
            Buffer.add_char buf ch;
            loop (ofs + 1)
        | _ ->
            let ofs' = Zed_utf8.unsafe_next entry ofs in
            Buffer.add_substring buf entry ofs (ofs' - ofs);
            loop ofs'
  in
  loop 0

let unescape line =
  let len = String.length line in
  let buf = Buffer.create len in
  let rec loop ofs size =
    if ofs = len then
      (Buffer.contents buf, size + 1)
    else
      match String.unsafe_get line ofs with
        | '\\' ->
            if ofs = len then begin
              Buffer.add_char buf '\\';
              (Buffer.contents buf, size + 3)
            end else begin
              match String.unsafe_get line (ofs + 1) with
                | 'n' ->
                    Buffer.add_char buf '\n';
                    loop (ofs + 2) (size + 2)
                | '\\' ->
                    Buffer.add_char buf '\\';
                    loop (ofs + 2) (size + 2)
                | _ ->
                    Buffer.add_char buf '\\';
                    loop (ofs + 1) (size + 2)
            end
        | ch when Char.code ch <= 127 ->
            Buffer.add_char buf ch;
            loop (ofs + 1) (size + 1)
        | _ ->
            let ofs' = Zed_utf8.unsafe_next line ofs in
            Buffer.add_substring buf line ofs (ofs' - ofs);
            loop ofs' (size + ofs' - ofs)
  in
  loop 0 0

let section = Lwt_log.Section.make "lambda-term(history)"

let safe_lockf fd cmd ofs =
  try_lwt
    Lwt_unix.lockf fd cmd ofs
  with exn ->
    lwt () = try_lwt Lwt_unix.close fd with _ -> return () in
    raise_lwt exn

let load history ?log ?(skip_empty=true) ?(skip_dup=true) fn =
  (* In case we do not load anything. *)
  history.old_count <- history.length;
  if history.max_entries = 0 || history.max_size = 0 then
    (* Do not bother loading the file for nothing... *)
    return ()
  else begin
    let log =
      match log with
        | Some func ->
            func
        | None ->
            fun line msg ->
              ignore (Lwt_log.error_f ~section "File %S, at line %d: %s" fn line msg)
    in
    try_lwt
      lwt fd = Lwt_unix.openfile fn [Unix.O_RDONLY] 0 in
      lwt () = safe_lockf fd Unix.F_RLOCK 0 in
      (try_lwt
         let ic = Lwt_io.of_fd ~mode:Lwt_io.input fd in
         let rec aux num =
           match_lwt Lwt_io.read_line_opt ic with
             | None ->
                 return ()
             | Some line ->
                 (try
                    let entry, size = unescape line in
                    if not (skip_empty && is_empty entry) && not (skip_dup && is_dup history entry) then begin
                      add_aux history entry size;
                      history.old_count <- history.length
                    end
                  with Zed_utf8.Invalid (msg, _) ->
                    log num msg);
                 aux (num + 1)
         in
         aux 1
       finally
         lwt () = safe_lockf fd Unix.F_ULOCK 0 in
         Lwt_unix.close fd)
    with Unix.Unix_error (Unix.ENOENT, _, _) ->
      return ()
  end

let rec skip_nodes node count =
  if count = 0 then
    node
  else
    skip_nodes node.prev (count - 1)

let rec copy history marker node skip_empty skip_dup =
  if node != marker then begin
    let line = escape node.data in
    if not (skip_empty && is_empty line) && not (skip_dup && is_dup history line) then
      add_aux history line node.size;
    copy history marker node.prev skip_empty skip_dup
  end

let rec save oc marker node =
  if node == marker then
    return ()
  else begin
    lwt () = Lwt_io.write_line oc node.data in
    save oc marker node.prev
  end

let save history ?max_size ?max_entries ?(skip_empty=true) ?(skip_dup=true) ?(append=true) ?(perm=0o666) fn =
  let max_size =
    match max_size with
      | Some m -> m
      | None -> history.max_size
  and max_entries =
    match max_entries with
      | Some m -> m
      | None -> history.max_entries
  in
  let history_save = create ~max_size ~max_entries [] in
  if history_save.max_size = 0 || history_save.max_entries = 0 then
    (* Just empty the history. *)
    Lwt_unix.openfile fn [Unix.O_CREAT; Unix.O_TRUNC] perm >>= Lwt_unix.close
  else begin
    lwt fd = Lwt_unix.openfile fn [Unix.O_RDWR; Unix.O_CREAT] perm in
    lwt () = safe_lockf fd Unix.F_LOCK 0 in
    try_lwt
      lwt old_count =
        if append then begin
          (* Load existing entries. *)
          let ic = Lwt_io.of_fd ~mode:Lwt_io.input fd in
          let rec aux count =
            match_lwt Lwt_io.read_line_opt ic with
              | None ->
                  history_save.old_count <- history_save.length;
                  return count
              | Some line ->
                  (* Do not bother unescaping. Tests remain the same
                     on the unescaped version. *)
                  if not (skip_empty && is_empty line) && not (skip_dup && is_dup history_save line) then
                    add_aux history_save line (String.length line + 1);
                  aux (count + 1)
          in
          aux 0
        end else
          return 0
      in
      let marker = history.entries.prev in
      (* Copy new entries into the saving history. *)
      copy history_save marker (skip_nodes marker.prev history.old_count) skip_empty skip_dup;
      lwt to_skip =
        if append && history_save.old_count = old_count then
          (* No old entries where removed, just write new entries at
             the end (and we are already at the end). *)
          return old_count
        else
          (* Otherwise empty the file. *)
          lwt _ = Lwt_unix.lseek fd 0 Unix.SEEK_SET in
          lwt () = Lwt_unix.ftruncate fd 0 in
          return 0
      in
      (* Save entries. *)
      let oc = Lwt_io.of_fd ~mode:Lwt_io.output fd in
      let marker = history_save.entries.prev in
      lwt () = save oc marker (skip_nodes marker.prev to_skip) in
      lwt () = Lwt_io.flush oc in
      history.old_count <- history.length;
      return ()
    finally
      lwt () = safe_lockf fd Unix.F_ULOCK 0 in
      Lwt_unix.close fd
  end
