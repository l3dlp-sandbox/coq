- **Changed:**
  :cmd:`Ltac2 Notation` without an explicit level puts the notation at level `1` instead of `5`
  when it starts with a string which is an identifier.
  Various notations have consequently changed level (e.g. `apply`).
  (`#20759 <https://github.com/rocq-prover/rocq/pull/20759>`_,
  fixes `#20616 <https://github.com/rocq-prover/rocq/issues/20616>`_,
  by Gaëtan Gilbert).
- **Changed:**
  well parenthesized notations (`match!`, `lazy_match!`, etc) are now at level `0` instead of `5`,
  and `now` is at level `1` instead of `6` (its argument is still at level `6`)
  (`#20759 <https://github.com/rocq-prover/rocq/pull/20759>`_,
  by Gaëtan Gilbert).
