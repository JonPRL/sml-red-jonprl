functor MlSyntax
  (type id
   type metavariable
   type jdg
   type term
   type vty) : ML_SYNTAX = 
struct
  type id = id
  type metavariable = metavariable
  type jdg = jdg
  type term = term
  type vty = vty

  type metas = (metavariable * Tm.valence) list

  datatype value =
     THUNK of cmd
   | VAR of id
   | NIL
   | ABS of value * value
   | METAS of metas
   | TERM of term

  and cmd =
     BIND of cmd * id * cmd
   | RET of value
   | FORCE of value
   | FN of id * vty * cmd
   | AP of cmd * value
   | PRINT of Pos.t option * value
   | REFINE of jdg * term
   | NU of metas * cmd
   | MATCH_ABS of value * id * id * cmd
   | MATCH_THM of value * id * id * cmd
   | ABORT
end
