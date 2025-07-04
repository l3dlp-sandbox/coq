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

(** {6 Nametab generic APIs } *)

module type NAMETAB = sig
  (** Common APIs on name tables. *)

  type elt
  (** The type of the elements of the name table (eg ModPath.t) *)

  val push : visibility -> full_path -> elt -> unit
  (** Add an element or modify its visibility.
      With visibility [Until], assume the element is new.
      With visibility [Exactly], assume the element is not new.
  *)

  val remove : full_path -> elt -> unit
  (** Remove an element. *)

  val shortest_qualid_gen : ?loc:Loc.t -> (Id.t -> bool) -> elt -> qualid
  (** [shortest_qualid_gen avoid v]: given an object [v] with full
      name Mylib.A.B.x, try to find the shortest among x, B.x, A.B.x
      and Mylib.A.B.x that denotes the same object.
      If [avoid] is [true] on [x] it is assumed to denote something else
      (so B.x is the shortest qualid that could be returned).

      @raise Not_found for unknown objects. *)

  val shortest_qualid : ?loc:Loc.t -> Id.Set.t -> elt -> qualid
  (** Like [shortest_qualid_gen] but using an id set instead of a closure. *)

  val pr : elt -> Pp.t
  (** Print using [shortest_qualid] and empty avoid set. *)

  val locate : qualid -> elt
  (** Globalize the given user-level reference.
      If any warnings are associated with the produced object, print
      them unless [nowarn:true] was given. *)

  val locate_all : qualid -> elt list
  (** Locate all elements with a given suffix. If the qualid is a
      valid absolute name, that element is first in the list. *)

  val completion_candidates : qualid -> elt list
  (** Return the elements that have the qualid as a prefix.
      UIs will usually compose with [shortest_qualid].
      Experimental APIs, please tell us if you use it. *)

  val to_path : elt -> full_path
  (** Return the absolute name for the given element. *)

  val of_path : full_path -> elt
  (** Return an element bound to an absolute path. *)

  val exists : full_path -> bool
  (** Returns whether this absolute path is taken. *)
end

module type WarnedTab = sig
  (** NAMETAB extended with warnings associated to some of the elements. *)

  include NAMETAB

  type warning_data

  val push : ?wdata:warning_data -> visibility -> full_path -> elt -> unit
  (** When [visibility] is [Until], [wdata] may be [Some _] in which
      case the warning data is associated to the element. *)

  val is_warned : elt -> warning_data option
  (** Return the warning data associated to the element. *)

  val warn : ?loc:Loc.t -> elt -> warning_data -> unit
  (** Emit the given warning data for the given element (if the warning is not disabled). *)

  val locate : ?nowarn:bool -> qualid -> elt
  (** Unless [nowarn:false] is given, if the found element is
      associated to a warning, that warning is emitted. *)
end

(** {6 Core nametabs } *)

module XRefs : WarnedTab
  with type elt = Globnames.extended_global_reference
   and type warning_data := Globnames.extended_global_reference UserWarn.with_qf

module Univs : NAMETAB with type elt = Univ.UGlobal.t

module Quality : NAMETAB with type elt = Sorts.QGlobal.t

(** Module types, modules and open modules/modtypes/sections form three separate name spaces
    (maybe this will change someday) *)
module ModTypes : NAMETAB with type elt = ModPath.t

module Modules : NAMETAB with type elt = ModPath.t

module OpenMods : NAMETAB with type elt = GlobDirRef.t

module CustomEntries : NAMETAB with type elt = Globnames.CustomName.t
(** Do not directly use [locate] with this, instead use the compat
    layer [Metasyntax.intern_custom_name]. *)

(** {6 Specializations for extended references } *)

(** These functions operate on [XRefs] but are about a subset of
    [extended_global_reference] for convenience. *)

val push : ?user_warns:Globnames.extended_global_reference UserWarn.with_qf -> visibility -> full_path -> GlobRef.t -> unit

val push_abbreviation : ?user_warns:Globnames.extended_global_reference UserWarn.with_qf -> visibility -> full_path -> Globnames.abbreviation -> unit

val locate : qualid -> GlobRef.t

val locate_all : qualid -> GlobRef.t list

val locate_constant : qualid -> Constant.t

val locate_abbreviation : qualid -> Globnames.abbreviation

val remove_abbreviation : full_path -> Globnames.abbreviation -> unit

val global_of_path : full_path -> GlobRef.t

val path_of_global : GlobRef.t -> full_path

val path_of_abbreviation : Globnames.abbreviation -> full_path

val shortest_qualid_of_global : ?loc:Loc.t -> Id.Set.t -> GlobRef.t -> qualid
val shortest_qualid_of_abbreviation : ?loc:Loc.t -> Id.Set.t -> Globnames.abbreviation -> qualid

(** Printing of global references using names as short as possible.
    @raise Not_found when the reference is not in the global tables. *)
val pr_global_env : Id.Set.t -> GlobRef.t -> Pp.t

(** Returns in particular the dirpath or the basename of the full path
   associated to global reference *)

val dirpath_of_global : GlobRef.t -> DirPath.t
val basename_of_global : GlobRef.t -> Id.t

(** These functions globalize user-level references into global
    references, like [locate] and co, but raise [GlobalizationError]
    for unbound qualid and [UserError] for type mismatches (eg
    [global_inductive] when the qualid is bound to a constructor) *)

val global : qualid -> GlobRef.t
val global_inductive : qualid -> inductive

(** {6 These functions declare (resp. return) the source location of the object if known } *)
(* XXX handle as part of the general nametab API? *)

val set_cci_src_loc : Globnames.extended_global_reference -> Loc.t -> unit
val cci_src_loc : Globnames.extended_global_reference -> Loc.t option

(** {6 Nametab generators } *)

module type ValueType = sig
  type t
  val equal : t -> t -> bool

  val is_var : t -> Id.t option
  (** Is this a variable (not handled by name tables)? *)

  module Map : CSig.UMapS with type key = t
end

module type StateInfo = sig
  (** Necessary data to declare the imperative state for a nametab. *)

  val stage : Summary.Stage.t
  val summary_name : string
end

(** Generate a nametab, without warning support. *)
module EasyNoWarn (M:sig include ValueType include StateInfo end) ()
  : NAMETAB with type elt = M.t

module type WarnInfo = sig
  type elt
  type data

  module Map : CSig.UMapS with type key = elt

  val stage : Summary.Stage.t
  val summary_name : string
  (** NB: This summary name must NOT be the same as the nametab summary name. *)

  val warn : ?loc:Loc.t -> elt -> data -> unit
end

(** Add warning support to an existing nametab. *)
module MakeWarned(M:NAMETAB)(W:WarnInfo with type elt = M.elt) ()
  : WarnedTab with type elt = M.elt and type warning_data := W.data

module type SimpleWarnS = sig
  (** Necessary data to declare a simple warning ([UserWarn.create_depr_and_user_warnings_qf]). *)
  val object_name : string
  val warning_name_base : string
end

(** Generate a nametab with simple warning support
    ([UserWarn.create_depr_and_user_warnings_qf]). *)
module Easy (M:sig include ValueType include StateInfo include SimpleWarnS end) ()
  : WarnedTab with type elt = M.t and type warning_data := M.t UserWarn.with_qf

(** {6 legacy APIs } *)
(* XXX deprecate? *)

val push_modtype : visibility -> full_path -> ModPath.t -> unit
val push_module : visibility -> full_path -> ModPath.t -> unit
val push_dir : visibility -> full_path -> GlobDirRef.t -> unit

val push_universe : visibility -> full_path -> Univ.UGlobal.t -> unit

(** Deprecation and user warn info *)

val is_warned_xref : Globnames.extended_global_reference -> Globnames.extended_global_reference UserWarn.with_qf option

val warn_user_warn_xref : ?loc:Loc.t -> Globnames.extended_global_reference UserWarn.with_qf -> Globnames.extended_global_reference -> unit

(** {6 The following functions perform globalization of qualified names } *)

(** These functions globalize a (partially) qualified name or fail with
   [Not_found] *)

val locate_extended : qualid -> Globnames.extended_global_reference
val locate_modtype : qualid -> ModPath.t
val locate_dir : qualid -> GlobDirRef.t
val locate_module : qualid -> ModPath.t
val locate_section : qualid -> full_path
val locate_universe : qualid -> Univ.UGlobal.t

val locate_extended_nowarn : qualid -> Globnames.extended_global_reference

(** These functions locate all global references with a given suffix;
   if [qualid] is valid as such, it comes first in the list *)

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

val extended_global_of_path : full_path -> Globnames.extended_global_reference

(** {6 These functions tell if the given absolute name is already taken } *)

val exists_cci : full_path -> bool
val exists_modtype : full_path -> bool
val exists_module : full_path -> bool
val exists_dir : full_path -> bool
val exists_universe : full_path -> bool

(** {6 These functions locate qualids into full user names } *)

val full_name_modtype : qualid -> full_path
val full_name_module : qualid -> full_path
val full_name_open_mod : qualid -> full_path

(** {6 Reverse lookup }
  Finding user names corresponding to the given
  internal name *)

(** Returns the full path bound to a global reference or syntactic
   definition, and the (full) dirpath associated to a module path *)

val path_of_module : ModPath.t -> full_path
val path_of_modtype : ModPath.t -> full_path

(** A universe_id might not be registered with a corresponding user name.
    @raise Not_found if the universe was not introduced by the user. *)
val path_of_universe : Univ.UGlobal.t -> full_path

(** The [shortest_qualid] functions given an object with [user_name]
   Mylib.A.B.x, try to find the shortest among x, B.x, A.B.x and
   Mylib.A.B.x that denotes the same object.
   @raise Not_found for unknown objects. *)

val shortest_qualid_of_modtype : ?loc:Loc.t -> ModPath.t -> qualid
val shortest_qualid_of_module : ?loc:Loc.t -> ModPath.t -> qualid
val shortest_qualid_of_dir : ?loc:Loc.t -> GlobDirRef.t -> qualid

(** In general we have a [UnivNames.universe_binders] around rather than a [Id.Set.t] *)
val shortest_qualid_of_universe : ?loc:Loc.t -> 'u Id.Map.t -> Univ.UGlobal.t -> qualid
