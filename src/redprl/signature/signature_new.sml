structure SignatureNew = 
struct
  structure EM = ElabMonad
  type 'a m = 'a EM.t

  structure Ast = RedPrlAst and Tm = RedPrlAbt and AJ = AtomicJudgment

  type ast = Ast.ast
  type sort = RedPrlSort.t
  type arity = Tm.O.Ar.t
  type abt = Tm.abt
  type ajdg = AJ.jdg

  exception todo
  fun ?e = raise e

  structure Ty = 
  struct
    datatype vty =
       ONE
     | DOWN of cty
     | TERM of sort
     | THM of sort
     | ABS of Tm.valence list * vty

    and cty = 
       UP of vty
  end

  fun @@ (f, x) = f x
  infixr @@

  fun >>= (m, k) = EM.bind k m
  infix >>=  

  (* The resolver environment *)
  structure Res :>
  sig
    type env

    val init : env

    val lookupId : env -> Pos.t option -> string -> Ty.vty m
    val extendId : env -> string -> Ty.vty -> env m

    val lookupVar : env -> Pos.t option -> string -> (Tm.variable * Tm.sort) m
    val lookupMeta : env -> Pos.t option -> string -> (Tm.metavariable * Tm.valence) m

    val extendVars : env -> string list * Tm.sort list -> ((Tm.variable * Tm.sort) list * env) m
    val extendMetas : env -> string list * Tm.valence list -> ((Tm.metavariable * Tm.valence) list * env) m
  end = 
  struct
    type env =
      {ids : Ty.vty StringListDict.dict,
       vars : (Tm.variable * Tm.sort) StringListDict.dict,
       metas : (Tm.metavariable * Tm.valence) StringListDict.dict}

    val init = 
      {ids = StringListDict.empty,
       vars = StringListDict.empty,
       metas = StringListDict.empty}

    fun lookup dict pos x = 
      case StringListDict.find dict x of 
         SOME r => EM.ret r
       | NONE => EM.fail (pos, Fpp.hsep [Fpp.text "Could not resolve name", Fpp.text x])
      
    fun lookupId (env : env) =
      lookup (#ids env)

    fun lookupVar (env : env) =
      lookup (#vars env)
      
    fun lookupMeta (env : env) =
      lookup (#metas env)      

    (* TODO: ensure that this name is not already used *)
    fun extendId {ids, vars, metas} nm vty =
      EM.ret
        {ids = StringListDict.insert ids nm vty,
         vars = vars,
         metas = metas}

    fun extendVars {ids, vars, metas} (xs, taus) =
      let
        val (gamma, vars') =
          ListPair.foldrEq
            (fn (x, tau, (gamma, vars)) =>
              let
                val x' = Sym.named x
              in
                ((x',tau) :: gamma, StringListDict.insert vars x (x', tau))
              end)
            ([], vars)
            (xs, taus)
        val env = {ids = ids, vars = vars', metas = metas}
      in    
        EM.ret (gamma, env)
      end
      handle exn =>
        EM.fail (NONE, Fpp.hsep [Fpp.text "extendVars: invalid arguments,", Fpp.text (exnMessage exn)])

    fun extendMetas {ids, vars, metas} (Xs, vls) =
      let
        val (psi, metas') =
          ListPair.foldrEq
            (fn (X, vl, (psi, metas)) =>
              let
                val X' = Metavar.named X
              in
                ((X',vl) :: psi, StringListDict.insert metas X (X', vl))
              end)
            ([], metas)
            (Xs, vls)
        val env = {ids = ids, vars = vars, metas = metas'}
      in
        EM.ret (psi, env)
      end
      handle _ =>
        EM.fail (NONE, Fpp.text "extendMetas: invalid arguments")
  end

  structure Src =
  struct
    type arguments = (string * Tm.valence) list

    datatype decl =
       DEF of {arguments : arguments, sort : sort, definiens : ast}
     | THM of {arguments : arguments, goal : ast, script : ast}
     | TAC of {arguments : arguments, script : ast}

    datatype cmd =
       PRINT of string
     | EXTRACT of string

    datatype elt = 
       DECL of string * decl * Pos.t
     | CMD of cmd * Pos.t

    type sign = elt list
  end

  (* external language *)
  structure ESyn =
  struct
    datatype value = 
       THUNK of cmd
     | VAR of string
     | NIL
     | ABS of (string * Tm.valence) list * value
     | TERM of ast * sort

    and cmd = 
       BIND of cmd * string * cmd
     | RET of value
     | FORCE of value
     | PRINT of Pos.t option * value
     | REFINE of ast * ast
     | NU of (string * Tm.valence) list * cmd

    fun compileSrcCmd pos : Src.cmd  -> cmd =
      fn Src.PRINT nm => PRINT (SOME pos, VAR nm)
       | Src.EXTRACT nm => PRINT (SOME pos, VAR nm) (* TODO *)

    fun compileSrcDecl (nm : string) : Src.decl -> cmd = 
      fn Src.DEF {arguments, sort, definiens} =>
         RET (ABS (arguments, TERM (definiens, sort)))

       | Src.TAC {arguments, script} =>
         RET (ABS (arguments, TERM (script, RedPrlSort.TAC)))

       | Src.THM {arguments, goal, script} =>
         NU (arguments, BIND (REFINE (goal, script), nm, RET (ABS (arguments, VAR nm))))

    val rec compileSrcSig : Src.sign -> cmd = 
      fn [] => 
         RET NIL
    
       | Src.CMD (c, pos) :: sign =>
         BIND (compileSrcCmd pos c, "_", compileSrcSig sign)
        
       | Src.DECL (nm, decl, _) :: sign =>
         BIND (compileSrcDecl nm decl, nm, compileSrcSig sign)
  end

  (* internal language *)
  structure ISyn =
  struct
    datatype value = 
       THUNK of cmd
     | VAR of string
     | NIL
     | ABS of (Tm.metavariable * Tm.valence) list * value
     | TERM of abt

    and cmd = 
       BIND of cmd * string * cmd
     | RET of value
     | FORCE of value
     | PRINT of Pos.t option * value
     | REFINE of ajdg * abt
     | NU of (Tm.metavariable * Tm.valence) list * cmd
  end

  (* semantic domain *)
  structure Sem = 
  struct
    datatype value = 
       THUNK of env * ISyn.cmd
     | THM of ajdg * abt
     | TERM of abt
     | ABS of (Tm.metavariable * Tm.valence) list * value
     | NIL

    withtype env = value StringListDict.dict * Tm.metavariable Tm.Metavar.Ctx.dict

    datatype cmd = RET of value

    val initEnv = (StringListDict.empty, Tm.Metavar.Ctx.empty)

    fun lookup (env : env) (nm : string) : value m =
      case StringListDict.find (#1 env) nm of 
         SOME v => EM.ret v
       | NONE => EM.fail (NONE, Fpp.hsep [Fpp.text "Could not find value of", Fpp.text nm, Fpp.text "in environment"])

    fun extend (env : env) (nm : string) (v : value) : env =
      (StringListDict.insert (#1 env) nm v, #2 env)

    fun freshenMetas (env : env) (psi : (Tm.metavariable * Tm.valence) list) : env = 
      let
        val clone = Tm.Metavar.named o Tm.Metavar.toString
        val rho = List.foldl (fn ((X, _), rho) => Tm.Metavar.Ctx.insert rho X (clone X)) (#2 env) psi      
      in
        (#1 env, rho)
      end

    (* TODO *)
    val rec ppValue : value -> Fpp.doc = 
      fn THUNK _ => Fpp.text "<thunk>"
       | THM (jdg, abt) => Fpp.text "<thm>"
       | TERM abt => TermPrinter.ppTerm abt
       | ABS (psi, v) =>
         Fpp.seq
           [Fpp.hsep
            [Fpp.collection
              (Fpp.char #"[")
              (Fpp.char #"]")
              Fpp.Atomic.comma
              (List.map (fn (X, vl) => Fpp.hsep [TermPrinter.ppMeta X, Fpp.Atomic.colon, TermPrinter.ppValence vl]) psi),
             Fpp.text "=>"],
            Fpp.nest 2 @@ Fpp.seq [Fpp.newline, ppValue v]]
       | NIL => Fpp.text "()"

    fun printVal (pos : Pos.t option, v : value) : unit m =
      EM.info (pos, ppValue v)
  end


  fun zipWithM (k : 'a * 'b -> 'c m) : 'a list * 'b list -> 'c list m =
    fn ([], []) =>
       EM.ret []
     
     | (x :: xs, y :: ys) =>
       k (x, y) >>= (fn z =>
         zipWithM k (xs, ys) >>= (fn zs =>
           EM.ret @@ z :: zs))

     | _ =>
       EM.fail (NONE, Fpp.text "zipWithM: length mismatch")

  local
    structure O = RedPrlOperator and S = RedPrlSort
  in
    fun lookupArity (renv : Res.env) (pos : Pos.t option) (opid : string) : arity m =
      Res.lookupId renv pos opid >>= (fn vty =>
        case vty of 
           Ty.ABS (vls, Ty.TERM tau) => EM.ret @@ (vls, tau)
         | Ty.ABS (vls, Ty.THM tau) => EM.ret @@ (vls, tau)
         | _ => EM.fail (NONE, Fpp.hsep [Fpp.text "Could not infer arity for opid", Fpp.text opid]))

    fun checkAbt (view, tau) : abt m =
      EM.ret @@ Tm.check (view, tau)
      handle exn => 
        EM.fail (NONE, Fpp.hsep [Fpp.text "Error resolving abt:", Fpp.text (exnMessage exn)])

    fun guessSort (renv : Res.env) (ast : ast) : sort m =
      let
        val pos = Ast.getAnnotation ast
      in
        case Ast.out ast of 
           Ast.` x =>
           Res.lookupVar renv pos x >>= (fn (_, tau) =>
             EM.ret tau)

         | Ast.$# (X, _) =>
           Res.lookupMeta renv pos X >>= (fn (_, (_, tau)) =>
             EM.ret tau)

         | Ast.$ (O.CUST (opid, _), _) =>
           lookupArity renv pos opid >>= (fn (_, tau) =>
             EM.ret tau)

         | Ast.$ (theta, _) =>
           (EM.ret @@ #2 (O.arity theta)
            handle _ => EM.fail (NONE, Fpp.text "Error guessing sort"))
      end

    fun resolveAjdg (renv : Res.env) (ast : ast) : ajdg m =
      resolveAst renv (ast, S.JDG) >>= (fn abt =>
        EM.ret @@ AJ.out abt
        handle _ =>
          EM.fail (NONE, Fpp.hsep [Fpp.text "Expected atomic judgment but got", TermPrinter.ppTerm abt]))

    and resolveAst (renv : Res.env) (ast : ast, tau : sort) : abt m =
      let
        val pos = Ast.getAnnotation ast
      in
        case Ast.out ast of 
           Ast.` x =>
           Res.lookupVar renv pos x >>= (fn (x', _) => 
             checkAbt (Tm.` x', tau))

         | Ast.$# (X, asts : ast list) =>
           Res.lookupMeta renv pos X >>= (fn (X', (taus : sort list, _)) => 
             zipWithM (resolveAst renv) (asts, taus) >>= (fn abts => 
               checkAbt (Tm.$# (X', abts), tau)))

         | Ast.$ (theta, bs) =>
           resolveOpr renv pos theta bs >>= (fn theta' =>
             let
               val (vls, tau) = O.arity theta'
             in
               zipWithM (resolveBnd renv) (vls, bs) >>= (fn bs' =>
                 checkAbt (Tm.$ (theta', bs'), tau))
             end)
        end

    and resolveBnd (renv : Res.env) ((taus, tau), Ast.\ (xs, ast)) : abt Tm.bview m =
      Res.extendVars renv (xs, taus) >>= (fn (xs', renv') =>
        resolveAst renv' (ast, tau) >>= (fn abt =>
          EM.ret @@ Tm.\ (List.map #1 xs', abt)))

    and resolveOpr (renv : Res.env) (pos : Pos.t option) (theta : O.operator) (bs : ast Ast.abs list) : O.operator m = 
      (case theta of 
         O.CUST (opid, NONE) =>
         lookupArity renv pos opid >>= (fn ar =>
           EM.ret @@ O.CUST (opid, SOME ar))

       | O.DEV_APPLY_LEMMA (opid, NONE, pat) => 
         lookupArity renv pos opid >>= (fn ar =>
           EM.ret @@ O.DEV_APPLY_LEMMA (opid, SOME ar, pat))

       | O.DEV_USE_LEMMA (opid, NONE) =>
         lookupArity renv pos opid >>= (fn ar =>
           EM.ret @@ O.DEV_USE_LEMMA (opid, SOME ar))

       | O.MK_ANY NONE =>
         let
           val [Ast.\ (_, ast)] = bs
         in
           guessSort renv ast >>= (fn tau =>
             EM.ret @@ O.MK_ANY (SOME tau))
         end

       | O.DEV_LET NONE =>
         let
           val [Ast.\ (_, jdg), _, _] = bs
         in
           resolveAjdg renv jdg >>= (fn ajdg =>
             EM.ret @@ O.DEV_LET @@ SOME @@ AJ.synthesis ajdg)
         end

       | th => EM.ret th)
       handle _ => 
         EM.fail (pos, Fpp.text "Error resolving operator")
  end

  fun resolveVal (renv : Res.env) : ESyn.value -> (ISyn.value * Ty.vty) m = 
    fn ESyn.THUNK cmd =>
       resolveCmd renv cmd >>= (fn (cmd', cty) =>
         EM.ret (ISyn.THUNK cmd', Ty.DOWN cty))

     | ESyn.VAR nm => 
       Res.lookupId renv NONE nm >>= (fn vty =>
         EM.ret (ISyn.VAR nm, vty))

     | ESyn.NIL =>
       EM.ret (ISyn.NIL, Ty.ONE)

     | ESyn.TERM (ast, tau) =>
       resolveAst renv (ast, tau) >>= (fn abt =>
         EM.ret (ISyn.TERM abt, Ty.TERM tau))

     | ESyn.ABS (psi, v) =>
       Res.extendMetas renv (ListPair.unzip psi) >>= (fn (psi', renv') =>
         resolveVal renv' v >>= (fn (v', vty) =>
           EM.ret (ISyn.ABS (psi', v'), Ty.ABS (List.map #2 psi', vty))))

  and resolveCmd (renv : Res.env) : ESyn.cmd -> (ISyn.cmd * Ty.cty) m = 
    fn ESyn.BIND (cmd1, nm, cmd2) =>
       resolveCmd renv cmd1 >>= (fn (cmd1', Ty.UP vty1) =>
         Res.extendId renv nm vty1 >>= (fn renv' =>
           resolveCmd renv' cmd2 >>= (fn (cmd2', cty2) =>
             EM.ret (ISyn.BIND (cmd1', nm, cmd2'), cty2))))

     | ESyn.RET v =>
       resolveVal renv v >>= (fn (v', vty) =>
         EM.ret (ISyn.RET v', Ty.UP vty))

     | ESyn.FORCE v =>
       resolveVal renv v >>= (fn (v', vty) =>
         case vty of 
            Ty.DOWN cty => EM.ret (ISyn.FORCE v', cty)
          | _ => EM.fail (NONE, Fpp.text "Expected down-shifted type"))

     | ESyn.PRINT (pos, v) =>
       resolveVal renv v >>= (fn (v', _) =>
         EM.ret (ISyn.PRINT (pos, v'), Ty.UP Ty.ONE))

     | ESyn.REFINE (ajdg, script) =>
       resolveAjdg renv ajdg >>= (fn ajdg' =>
         resolveAst renv (script, RedPrlSort.TAC) >>= (fn script' =>
           EM.ret (ISyn.REFINE (ajdg', script'), Ty.UP (Ty.THM (AJ.synthesis ajdg')))))

     | ESyn.NU (psi, cmd) =>
       Res.extendMetas renv (ListPair.unzip psi) >>= (fn (psi', renv') =>
         resolveCmd renv' cmd >>= (fn (cmd', cty) =>
           EM.ret (ISyn.NU (psi', cmd'), cty)))


  structure MiniSig : MINI_SIGNATURE = 
  struct
    type opid = string
    type abt = abt
    type sign = Sem.env

    fun opidSpec env opid args = ?todo
    fun unfoldOpid env opid args = ?todo
  end

  structure Refiner = Refiner (MiniSig)

  fun evalCmd (env : Sem.env) : ISyn.cmd -> Sem.cmd m =
    fn ISyn.BIND (cmd1, x, cmd2) =>
       evalCmd env cmd1 >>= (fn Sem.RET s =>
         evalCmd (Sem.extend env x s) cmd2)

     | ISyn.RET v => 
       evalVal env v >>= (fn s =>
         EM.ret @@ Sem.RET s)

     | ISyn.FORCE v => 
       evalVal env v >>= (fn s =>
         case s of 
            Sem.THUNK (env', cmd) => evalCmd env' cmd
          | _ => EM.fail (NONE, Fpp.text "evalCmd/ISyn.FORCE expected Sem.THUNK"))

     | ISyn.PRINT (pos, v) =>
       evalVal env v >>= (fn s => 
         Sem.printVal (pos, s) >>= (fn _ => 
           EM.ret @@ Sem.RET @@ Sem.NIL))

     | ISyn.REFINE (ajdg, script) =>
       ?todo
    
     | ISyn.NU (psi, cmd) =>
       evalCmd (Sem.freshenMetas env psi) cmd

  and evalVal (env : Sem.env) : ISyn.value -> Sem.value m =
    fn ISyn.THUNK cmd => 
       EM.ret @@ Sem.THUNK (env, cmd)

     | ISyn.VAR nm =>
       Sem.lookup env nm

     | ISyn.NIL =>
       EM.ret Sem.NIL

     | ISyn.ABS (psi, v) =>
       evalVal env v >>= (fn s =>
         EM.ret @@ Sem.ABS (psi, s))

     | ISyn.TERM abt =>
       EM.ret @@ Sem.TERM (Tm.renameMetavars (#2 env) abt)
     
  structure L = RedPrlLog

  val checkAlg : ('a, bool) EM.alg =
    {warn = fn (msg, _) => (L.print L.WARN msg; false),
     info = fn (msg, r) => (L.print L.INFO msg; r),
     dump = fn (msg, r) => (L.print L.DUMP msg; r),
     init = true,
     succeed = fn (_, r) => r,
     fail = fn (msg, _) => (L.print L.FAIL msg; false)}
     

  fun check (sign : Src.sign) : bool = 
    let
      val ecmd : ESyn.cmd = ESyn.compileSrcSig sign
      val elab =
        resolveCmd Res.init ecmd >>= (fn (cmd, _) =>
          evalCmd Sem.initEnv cmd)
    in
      EM.fold checkAlg elab
    end
end
