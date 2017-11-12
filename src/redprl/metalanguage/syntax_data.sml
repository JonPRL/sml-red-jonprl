structure SyntaxData = 
struct
  structure Var = AbtSymbol ()
  structure Row = StringListDict

  type 'a row = 'a Row.dict
  type 'a con = string * 'a

  datatype vtype = 
     UNIT
   | TENSOR of vtype row
   | PLUS of vtype row
   | DOWN of ctype
   | PROOF
   | OEXP
   | META

  and ctype = 
     UP of vtype 
   | OBJ of ctype row
   | ARR of vtype * ctype

  structure I = 
  struct
    datatype vpat = 
       PTUPLE of vpat row
     | PCON of vpat row
     | PVAR of Var.t
     | PNULL

    datatype vterm =
       VNEU of vneu
     | TUPLE of vterm row
     | CON of vterm con
     | THUNK of cterm
     | VNULL

    and vneu = 
       VAR of Var.t
     | VTERM of vterm * vtype

   and cterm = 
      CNEU of cneu
    | FUN of vpat * cterm
    | RECORD of cterm row
    | LET of vpat * cneu * cterm
    | RET of vterm
  
   and cneu =
      FORCE of vneu
    | PROJ of cneu * string
    | APP of cneu * vterm
    | CTERM of cterm * ctype
  end

  structure E = 
  struct
    type var = string
    datatype term =
       VAR of string
     | LET of decl list * term
     | RCD of term row

    and decl = DECL (* TODO *)
    and pat = PAT (* TODO *)
  end
end