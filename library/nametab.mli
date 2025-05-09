(************************************************************************)
(*         *      The Rocq Prover / The Rocq Development Team           *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Names
open Libnames

(** This module contains the tables for globalization. *)

(** These globalization tables associate internal object references to
    qualified names (qualid). There are three classes of names:

    - 1a) internal kernel names: [kernel_name], [constant], [inductive],
         [module_path], [DirPath.t]

    - 1b) other internal names: [global_reference], [abbreviation],
        [extended_global_reference], [global_dir_reference], ...

    - 2) full, non ambiguous user names: [full_path]

    - 3) non necessarily full, possibly ambiguous user names: [reference]
        and [qualid]
*)

(** Most functions in this module fall into one of the following categories:
{ul {- [push : visibility -> full_user_name -> object_reference -> unit]

     Registers the [object_reference] to be referred to by the
     [full_user_name] (and its suffixes according to [visibility]).
     [full_user_name] can either be a [full_path] or a [DirPath.t].
   }
   {- [exists : full_user_name -> bool]

     Is the [full_user_name] already attributed as an absolute user name
     of some object?
   }
   {- [locate : qualid -> object_reference]

     Finds the object referred to by [qualid] or raises [Not_found]
   }
   {- [full_name : qualid -> full_user_name]

     Finds the full user name referred to by [qualid] or raises [Not_found]
   }
   {- [shortest_qualid_of : object_reference -> user_name]

     The [user_name] can be for example the shortest non ambiguous [qualid] or
     the [full_user_name] or [Id.t]. Such a function can also have a
     local context argument.}}

*)

(** to this type are mapped [DirPath.t]'s in the nametab *)
module GlobDirRef : sig
  type t =
    | DirOpenModule of ModPath.t
    | DirOpenModtype of ModPath.t
    | DirOpenSection of full_path
  val equal : t -> t -> bool
end

exception GlobalizationError of qualid

(** Raises a globalization error *)
val error_global_not_found : info:Exninfo.info -> qualid -> 'a

(** {6 Register visibility of things } *)

(** The visibility can be registered either
   - for all suffixes not shorter then a given int -- when the
   object is loaded inside a module -- or
   - for a precise suffix, when the module containing (the module
   containing ...) the object is opened (imported)

*)

type visibility = Until of int | Exactly of int

val map_visibility : (int -> int) -> visibility -> visibility

val push : ?user_warns:Globnames.extended_global_reference UserWarn.with_qf -> visibility -> full_path -> GlobRef.t -> unit
val push_modtype : visibility -> full_path -> ModPath.t -> unit
val push_module : visibility -> full_path -> ModPath.t -> unit
val push_dir : visibility -> full_path -> GlobDirRef.t -> unit
val push_abbreviation : ?user_warns:Globnames.extended_global_reference UserWarn.with_qf -> visibility -> full_path -> Globnames.abbreviation -> unit

val push_universe : visibility -> full_path -> Univ.UGlobal.t -> unit
val push_sort : visibility -> full_path -> Sorts.QGlobal.t -> unit

(** Deprecation and user warn info *)

val is_warned_xref : Globnames.extended_global_reference -> Globnames.extended_global_reference UserWarn.with_qf option

val warn_user_warn_xref : ?loc:Loc.t -> Globnames.extended_global_reference UserWarn.with_qf -> Globnames.extended_global_reference -> unit

(** {6 The following functions perform globalization of qualified names } *)

(** These functions globalize a (partially) qualified name or fail with
   [Not_found] *)

val locate : qualid -> GlobRef.t
val locate_extended : qualid -> Globnames.extended_global_reference
val locate_constant : qualid -> Constant.t
val locate_abbreviation : qualid -> Globnames.abbreviation
val locate_modtype : qualid -> ModPath.t
val locate_dir : qualid -> GlobDirRef.t
val locate_module : qualid -> ModPath.t
val locate_section : qualid -> full_path
val locate_universe : qualid -> Univ.UGlobal.t
val locate_quality : qualid -> Sorts.QGlobal.t

val locate_extended_nowarn : qualid -> Globnames.extended_global_reference

(** Remove the binding to an abbreviation *)

val remove_abbreviation : full_path -> Globnames.abbreviation -> unit

(** These functions globalize user-level references into global
   references, like [locate] and co, but raise a nice error message
   in case of failure *)

val global : qualid -> GlobRef.t
val global_inductive : qualid -> inductive

(** These functions locate all global references with a given suffix;
   if [qualid] is valid as such, it comes first in the list *)

val locate_all : qualid -> GlobRef.t list
val locate_extended_all : qualid -> Globnames.extended_global_reference list
val locate_extended_all_dir : qualid -> GlobDirRef.t list
val locate_extended_all_modtype : qualid -> ModPath.t list
val locate_extended_all_module : qualid -> ModPath.t list

(** Experimental completion support, API is _unstable_ *)
val completion_canditates : qualid -> Globnames.extended_global_reference list
(** [completion_canditates qualid] will return the list of global
    references that have [qualid] as a prefix. UI usually will want to
    compose this with [shortest_qualid_of_global] *)

(** Mapping a full path to a global reference *)

val global_of_path : full_path -> GlobRef.t
val extended_global_of_path : full_path -> Globnames.extended_global_reference

(** {6 These functions tell if the given absolute name is already taken } *)

val exists_cci : full_path -> bool
val exists_modtype : full_path -> bool
val exists_module : full_path -> bool
val exists_dir : full_path -> bool
val exists_universe : full_path -> bool
val exists_sort : full_path -> bool

(** {6 These functions declare (resp. return) the source location of the object if known } *)

val set_cci_src_loc : Globnames.extended_global_reference -> Loc.t -> unit
val cci_src_loc : Globnames.extended_global_reference -> Loc.t option

(** {6 These functions locate qualids into full user names } *)

val full_name_modtype : qualid -> full_path
val full_name_module : qualid -> full_path

(** {6 Reverse lookup }
  Finding user names corresponding to the given
  internal name *)

(** Returns the full path bound to a global reference or syntactic
   definition, and the (full) dirpath associated to a module path *)

val path_of_abbreviation : Globnames.abbreviation -> full_path
val path_of_global : GlobRef.t -> full_path
val path_of_module : ModPath.t -> full_path
val path_of_modtype : ModPath.t -> full_path

(** A universe_id might not be registered with a corresponding user name.
    @raise Not_found if the universe was not introduced by the user. *)
val path_of_universe : Univ.UGlobal.t -> full_path

(** Returns in particular the dirpath or the basename of the full path
   associated to global reference *)

val dirpath_of_global : GlobRef.t -> DirPath.t
val basename_of_global : GlobRef.t -> Id.t

(** Printing of global references using names as short as possible.
    @raise Not_found when the reference is not in the global tables. *)
val pr_global_env : Id.Set.t -> GlobRef.t -> Pp.t


(** The [shortest_qualid] functions given an object with [user_name]
   Mylib.A.B.x, try to find the shortest among x, B.x, A.B.x and
   Mylib.A.B.x that denotes the same object.
   @raise Not_found for unknown objects. *)

val shortest_qualid_of_global : ?loc:Loc.t -> Id.Set.t -> GlobRef.t -> qualid
val shortest_qualid_of_abbreviation : ?loc:Loc.t -> Id.Set.t -> Globnames.abbreviation -> qualid
val shortest_qualid_of_modtype : ?loc:Loc.t -> ModPath.t -> qualid
val shortest_qualid_of_module : ?loc:Loc.t -> ModPath.t -> qualid
val shortest_qualid_of_dir : ?loc:Loc.t -> full_path -> qualid

(** In general we have a [UnivNames.universe_binders] around rather than a [Id.Set.t] *)
val shortest_qualid_of_universe : ?loc:Loc.t -> 'u Id.Map.t -> Univ.UGlobal.t -> qualid

val pr_depr_xref : Globnames.extended_global_reference -> Pp.t

val shortest_qualid_of_quality : ?loc:Loc.t -> 'u Id.Map.t -> Sorts.QGlobal.t -> qualid

(** {5 Generic name handling} *)

(** NOT FOR PUBLIC USE YET. Plugin writers, please do not rely on this API. *)

module type EqualityType =
sig
  type t
  val equal : t -> t -> bool
end

module type NAMETREE = sig
  type elt
  type t

  val empty : t
  val push : visibility -> full_path -> elt -> t -> t
  val locate : qualid -> t -> elt
  val find : full_path -> t -> elt
  val remove : full_path -> t -> t
  val exists : full_path -> t -> bool
  val full_path : qualid -> t -> full_path
  val shortest_qualid_gen : ?loc:Loc.t -> (Id.t -> bool) -> full_path -> t -> qualid
  val shortest_qualid : ?loc:Loc.t -> Id.Set.t -> full_path -> t -> qualid
  val find_prefixes : qualid -> t -> elt list
  val match_prefixes : qualid -> t -> elt list
end

module Make (E : EqualityType) :
  NAMETREE with type elt = E.t
