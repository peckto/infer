(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
module F = Format

let textual_ext = ".sil"

let textual_subcommand = "compile-infer"

(** Utility functions to work with hackc output. *)
module OutputLine = struct
  type t =
    | UnitStart of string  (** Start of a unit with a given filename *)
    | UnitEnd of string  (** End of a unit with a given filename *)
    | Regular of string  (** Regular line of output *)

  let start_marker = "// TEXTUAL UNIT START"

  let end_marker = "// TEXTUAL UNIT END"

  let detect line =
    match String.chop_prefix line ~prefix:start_marker with
    | Some filename ->
        UnitStart (String.strip filename)
    | None -> (
      match String.chop_prefix line ~prefix:end_marker with
      | Some filename ->
          UnitEnd (String.strip filename)
      | None ->
          Regular line )
end

(** Utility wrapper around [In_channel.t] that provides one line of look-ahead. *)
module Peekable_in_channel = struct
  type t =
    { mutable cur_line: string option
          (** [cur_line] is the last line read from [ic], None only on EOF. *)
    ; ic: In_channel.t }

  let mk ic =
    let cur_line = In_channel.input_line ic in
    {cur_line; ic}


  let input_line t =
    let line = t.cur_line in
    if Option.is_some line then t.cur_line <- In_channel.input_line t.ic ;
    line


  let rec input_line_until_nonempty t =
    match input_line t with
    | Some line when not (String.is_empty line) ->
        Some line
    | Some _ ->
        input_line_until_nonempty t
    | None ->
        None
end

(** Utility functions to consume (potentially) multi-file hackc output. *)
module Unit : sig
  type t

  val extract_units : In_channel.t -> t Seq.t
  (** Returns a lazy sequence of units extracted from the channel. *)

  val capture_unit : t -> (unit, unit) Result.t
end = struct
  type t = {source_path: string; content: string}

  let extract_unit pic =
    let buf = Buffer.create 4096 in
    let rec find_start line_opt =
      match line_opt with
      | None ->
          None
      | Some line -> (
        match OutputLine.detect line with
        | UnitStart filename ->
            Buffer.clear buf ;
            acc_unit filename (Peekable_in_channel.input_line pic)
        | _ ->
            L.user_warning "Unexpected line outside of a textual unit: %s@." line ;
            find_start (Peekable_in_channel.input_line_until_nonempty pic) )
    and acc_unit source_path line_opt =
      match line_opt with
      | None ->
          L.user_warning "Unfinished unit: %s@." source_path ;
          None
      | Some line -> (
        match OutputLine.detect line with
        | UnitEnd end_filename when String.equal source_path end_filename ->
            let content = Buffer.contents buf in
            Buffer.clear buf ;
            Some {source_path; content}
        | UnitEnd end_filename ->
            L.user_warning "Unexpected end of another unit: expected=%s, actual=%s@." source_path
              end_filename ;
            find_start (Peekable_in_channel.input_line_until_nonempty pic)
        | UnitStart _ ->
            L.user_warning "Unexpected start of another unit: %s@." line ;
            find_start (Some line)
        | Regular line ->
            (* Accumulate lines in the state *)
            Buffer.add_string buf line ;
            Buffer.add_char buf '\n' ;
            acc_unit source_path (Peekable_in_channel.input_line pic) )
    in
    find_start (Peekable_in_channel.input_line_until_nonempty pic)


  let extract_units ic =
    let pic = Peekable_in_channel.mk ic in
    Seq.of_dispenser (fun () -> extract_unit pic)


  (** Flatten a/b/c as a-b-c. Special dirs .. and . are abbreviated. *)
  let flatten_path path =
    let normalized_path = Utils.normalize_path path in
    let path_parts = Filename.parts normalized_path in
    let process_part = function ".." -> ["dd"] | "." -> [] | other -> [other] in
    List.bind path_parts ~f:process_part |> String.concat ~sep:"-"


  let to_textual_filename path =
    let flat = flatten_path path in
    let noext = Filename.chop_extension flat in
    noext ^ textual_ext


  let dump_textual_to_tmp_file source_path content =
    let textual_filename = to_textual_filename source_path in
    let out_file =
      Filename.temp_file ~in_dir:(ResultsDir.get_path Temporary) textual_filename "sil"
    in
    Out_channel.write_all out_file ~data:content


  (** Translate and capture a textual unit. Returns [true] on success and [false] on failure. *)
  let capture_unit {source_path; content} =
    L.debug Capture Quiet "Capturing %s@." source_path ;
    let open TextualParser in
    let line_map = LineMap.create content in
    let trans = TextualFile.translate (TranslatedFile {source_path; content; line_map}) in
    let res =
      match trans with
      | Ok sil ->
          TextualFile.capture sil ;
          Ok ()
      | Error (sourcefile, errs) ->
          List.iter errs ~f:(log_error sourcefile) ;
          Error ()
    in
    if Config.debug_mode || Result.is_error trans then dump_textual_to_tmp_file source_path content ;
    res
end

(** Process hackc output from [ic] extracting and capturing individual textual units.

    The structure of hackc output is as follows:

    - START MARKER <source path>
    - <content>
    - END MARKER <source path>
    - ... repeat

    The function below processes such input from [ic] line by line and does some light-weight error
    detection mainly to detect situations when different compilation units get mixed up in the
    output (this shouldn't happen normally).

    When the whole compilation unit has been accumulated, [Unit.capture_unit] is called. *)
let process_output ic =
  let units = Unit.extract_units ic in
  let n_captured, n_error = (ref 0, ref 0) in
  Seq.iter
    (fun unit ->
      match Unit.capture_unit unit with Ok () -> incr n_captured | Error () -> incr n_error )
    units ;
  (!n_captured, !n_error)


(** Start hackc [compiler] with [args] in a subprocess returning its pid and stdout. *)
let start_hackc compiler args =
  let stderr_log = Filename.temp_file ~in_dir:(ResultsDir.get_path Temporary) "hackc" "stderr" in
  let escaped_cmd = List.map ~f:Escape.escape_shell (compiler :: args) |> String.concat ~sep:" " in
  let redirected_cmd = F.sprintf "exec %s 2>%s" escaped_cmd stderr_log in
  let {Unix.Process_info.stdin; stdout; stderr; pid} =
    Unix.create_process ~prog:"sh" ~args:["-c"; redirected_cmd]
  in
  Unix.close stdin ;
  Unix.close stderr ;
  let stdout = Unix.in_channel_of_descr stdout in
  (pid, stdout)


(** Run hackc [compiler] with [args] and consume results of translation from its stdout. We don't do
    any pre-processing of [args] and let hackc deal with multiple files on its own. We also pipe
    stderr into a temp file just in case. *)
let compile compiler args =
  let hackc_pid, hackc_stdout = start_hackc compiler args in
  let n_captured, n_error = process_output hackc_stdout in
  In_channel.close hackc_stdout ;
  match Unix.waitpid hackc_pid with
  | Ok () ->
      L.progress "Finished capture: success %d files, error %d files.@." n_captured n_error ;
      if (not Config.keep_going) && n_error > 0 then
        L.die ExternalError
          "There were errors during capture. Re-run with --keep-going to ignore the errors."
  | Error _ as status ->
      L.die ExternalError "Error executing hackc: %s@\n" (Unix.Exit_or_signal.to_string_hum status)


let capture ~prog ~args =
  if List.exists args ~f:(fun arg -> String.equal arg textual_subcommand) then
    (* In force_integration mode we should use whatever program is provided on the command line to
       support cases where hackc is invoked via buck run or similar. *)
    let compiler = if Option.is_some Config.force_integration then prog else Config.hackc_binary in
    compile compiler args
  else L.die UserError "hackc command line is missing %s subcommand" textual_subcommand
