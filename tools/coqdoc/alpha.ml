(************************************************************************)
(*         *      The Rocq Prover / The Rocq Development Team           *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Common

let norm_char_latin1 c = match Char.uppercase_ascii c with
  | '\192'..'\198' -> 'A'
  | '\199' -> 'C'
  | '\200'..'\203' -> 'E'
  | '\204'..'\207' -> 'I'
  | '\209' -> 'N'
  | '\210'..'\214' -> 'O'
  | '\217'..'\220' -> 'U'
  | '\221' -> 'Y'
  | c -> c

let norm_char_utf8 c = Char.uppercase_ascii c

let norm_char c =
  if !prefs.encoding.utf8 then norm_char_utf8 c else
  if !prefs.encoding.latin1 then norm_char_latin1 c else
  Char.uppercase_ascii c

let norm_string = String.map (fun s -> norm_char s)

let compare_char c1 c2 = match norm_char c1, norm_char c2 with
  | ('A'..'Z' as c1), ('A'..'Z' as c2) -> compare c1 c2
  | 'A'..'Z', _ -> -1
  | _, 'A'..'Z' -> 1
  | '_', _ -> -1
  | _, '_' -> 1
  | c1, c2 -> compare c1 c2

let compare_string s1 s2 =
  let n1 = String.length s1 in
  let n2 = String.length s2 in
  let rec cmp i =
    if i == n1 || i == n2 then
      n1 - n2
    else
      let c = compare_char s1.[i] s2.[i] in
      if c == 0 then cmp (succ i) else c
  in
  cmp 0
