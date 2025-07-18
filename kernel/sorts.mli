(************************************************************************)
(*         *      The Rocq Prover / The Rocq Development Team           *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(** {6 The sorts of CCI. } *)

module QGlobal :
sig

  type t

  val make : Names.DirPath.t -> Names.Id.t -> t
  val repr : t -> Names.DirPath.t * Names.Id.t
  val equal : t -> t -> bool
  val hash : t -> int
  val compare : t -> t -> int
  val to_string : t -> string

end

module QVar :
sig
  type t

  val var_index : t -> int option

  val make_var : int -> t
  val make_unif : string -> int -> t
  val make_global : QGlobal.t -> t

  val equal : t -> t -> bool
  val compare : t -> t -> int

  val hash : t -> int

  val raw_pr : t -> Pp.t
  (** Using this is incorrect when names are available, typically from an evar map. *)

  val to_string : t -> string
  (** Debug printing *)

  type repr =
    | Var of int
    | Unif of string * int
    | Global of QGlobal.t

  val repr : t -> repr
  val of_repr : repr -> t

  module Set : CSig.SetS with type elt = t

  module Map : CMap.ExtS with type key = t and module Set := Set
end

module Quality : sig
  type constant = QProp | QSProp | QType
  type t = QVar of QVar.t | QConstant of constant

  module Constants : sig
    val equal : constant -> constant -> bool
    val compare : constant -> constant -> int
    val eliminates_to : constant -> constant -> bool
    val pr : constant -> Pp.t
  end

  val qprop : t
  val qsprop : t
  val qtype : t
  val is_qprop : t -> bool
  val is_qsprop : t -> bool
  val is_qtype : t -> bool

  val var : int -> t
  (** [var i] is [QVar (QVar.make_var i)] *)

  val global : QGlobal.t -> t
  (** [global i] is [QVar (QVar.make_global i)] *)

  val is_var : t -> bool

  val var_index : t -> int option

  val equal : t -> t -> bool

  val compare : t -> t -> int

  val eliminates_to : t -> t -> bool

  val pr : (QVar.t -> Pp.t) -> t -> Pp.t

  val raw_pr : t -> Pp.t

  val all_constants : t list
  val all : t list
  (* Returns a dummy variable *)

  val hash : t -> int

  val hcons : t Hashcons.f

  (* XXX Inconsistent naming: this one should be subst_fn *)
  val subst : (QVar.t -> t) -> t -> t

  val subst_fn : t QVar.Map.t -> QVar.t -> t

  module Set : CSig.SetS with type elt = t

  module Map : CMap.ExtS with type key = t and module Set := Set

  type 'q pattern =
    PQVar of 'q | PQConstant of constant

  val pattern_match : int option pattern -> t -> ('t, t, 'u) Partial_subst.t -> ('t, t, 'u) Partial_subst.t option
end

module QConstraint : sig
  type kind = Equal | Leq

  val pr_kind : kind -> Pp.t

  type t = Quality.t * kind * Quality.t

  val equal : t -> t -> bool

  val compare : t -> t -> int

  val trivial : t -> bool

  val pr : (QVar.t -> Pp.t) -> t -> Pp.t

  val raw_pr : t -> Pp.t
end

module QConstraints : sig include CSig.SetS with type elt = QConstraint.t

  val trivial : t -> bool

  val pr : (QVar.t -> Pp.t) -> t -> Pp.t
end

val enforce_eq_quality : Quality.t -> Quality.t -> QConstraints.t -> QConstraints.t

val enforce_leq_quality : Quality.t -> Quality.t -> QConstraints.t -> QConstraints.t

module QUConstraints : sig

  type t = QConstraints.t * Univ.Constraints.t

  val union : t -> t -> t

  val empty : t
end

type t = private
  | SProp
  | Prop
  | Set
  | Type of Univ.Universe.t
  | QSort of QVar.t * Univ.Universe.t

val sprop : t
val set  : t
val prop : t
val type1  : t
val qsort : QVar.t -> Univ.Universe.t -> t
val make : Quality.t -> Univ.Universe.t -> t

val equal : t -> t -> bool
val compare : t -> t -> int
val eliminates_to : t -> t -> bool
val hash : t -> int

val is_sprop : t -> bool
val is_set : t -> bool
val is_prop : t -> bool
val is_small : t -> bool
val quality : t -> Quality.t

val hcons : t Hashcons.f

val sort_of_univ : Univ.Universe.t -> t
val univ_of_sort : t -> Univ.Universe.t

val levels : t -> Univ.Level.Set.t

val super : t -> t

val subst_fn : (QVar.t -> Quality.t) * (Univ.Universe.t -> Univ.Universe.t)
  -> t -> t

(** On binders: is this variable proof relevant *)
(* TODO put in submodule or new file *)
type relevance = Relevant | Irrelevant | RelevanceVar of QVar.t

val relevance_hash : relevance -> int

val relevance_equal : relevance -> relevance -> bool

val relevance_subst_fn : (QVar.t -> Quality.t) -> relevance -> relevance

val relevance_of_sort : t -> relevance

val debug_print : t -> Pp.t
val pr : (QVar.t -> Pp.t) -> (Univ.Universe.t -> Pp.t) -> t -> Pp.t
val raw_pr : t -> Pp.t

type ('q, 'u) pattern =
  | PSProp | PSSProp | PSSet | PSType of 'u | PSQSort of 'q * 'u

val pattern_match : (int option, int option) pattern -> t -> ('t, Quality.t, Univ.Level.t) Partial_subst.t -> ('t, Quality.t, Univ.Level.t) Partial_subst.t option
