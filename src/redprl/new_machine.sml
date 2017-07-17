signature CLOSURE = 
sig
  type environment
  type param = RedPrlAbt.param
  type term = RedPrlAbt.abt
  type sort = RedPrlAbt.sort
  type psort = RedPrlAbt.psort
  type valence = RedPrlAbt.valence
  type 'a binder = 'a RedPrlAbt.bview

  datatype 'a closure = <: of 'a * environment

  val variable : (Var.t * sort) -> environment -> term closure
  val metavariable : (Metavar.t * (param * psort) list * term list * sort) -> environment -> term closure

  structure Env :
  sig
    type t = environment

    val empty : t
    val lookupSym : t -> Sym.t -> param
    val forceParam : t -> param -> param
    val forceTerm  : t -> term -> term

    val insertMeta : Metavar.t -> term closure binder -> t -> t
    val insertVar : Var.t -> term closure -> t -> t
    val insertSym : Sym.t -> param -> t -> t
  end
end

structure Closure :> CLOSURE = 
struct
  structure Tm = RedPrlAbt and P = RedPrlParameterTerm
  type param = Tm.param
  type term = Tm.abt
  type sort = Tm.sort
  type psort = Tm.psort
  type valence = Tm.valence
  type 'a binder = 'a Tm.bview

  type shallow_env =
    {vars: Tm.abt Var.Ctx.dict,
     syms: Tm.param Sym.Ctx.dict}

  datatype 'a closure = <: of 'a * environment
  and environment = ** of deep_env * shallow_env list
  withtype deep_env = 
    {metas: Tm.abt closure Tm.bview Metavar.Ctx.dict,
     vars: Tm.abt closure Var.Ctx.dict,
     syms: Tm.param Sym.Ctx.dict}


  infix 3 <:
  infix 4 **

  structure Env = 
  struct
    type t = environment
    local
      val emptyDeep = {metas = Metavar.Ctx.empty, vars = Var.Ctx.empty, syms = Sym.Ctx.empty}
    in
      val empty =
        emptyDeep ** []
    end

    local
      fun lookupSymDeep (E : deep_env) u = 
        Sym.Ctx.lookup (#syms E) u 
        handle Sym.Ctx.Absent => 
          P.ret u

      fun lookupSymShallow (F : shallow_env) u = 
        Sym.Ctx.lookup (#syms F) u 
        handle Sym.Ctx.Absent => 
          P.ret u

      (* Favonia: is this correct? To get the value of a symbol from the list of final substitutions,
         do we have to walk through the whole list and apply all possible substitutions? *)
      fun lookupSymFinal L u = 
        case L of 
           [] => P.ret u
         | F :: L => P.bind (lookupSymFinal L) (lookupSymShallow F u)
    in
      (* First, lookup the symbol in E; then, apply whatever substitutions are in L. *)
      fun lookupSym (E ** L) u =
        P.bind (lookupSymFinal L) (lookupSymDeep E u)
    end

    fun forceParam (E ** L) = 
      P.bind (lookupSym (E ** L))

    fun forceTerm (E ** L) =
      raise Fail "TODO"

    fun insertMeta x bndCl ({metas, vars, syms} ** L) =
      {metas = Metavar.Ctx.insert metas x bndCl, vars = vars, syms = syms} 
        ** L

    fun insertVar x cl ({metas, vars, syms} ** L) = 
      {metas = metas, vars = Var.Ctx.insert vars x cl, syms = syms}
        ** L

    fun insertSym u r ({metas, vars, syms} ** L) = 
      {metas = metas, vars = vars, syms = Sym.Ctx.insert syms u r}
        ** L
  end

  local
    open Tm infix $# \

    (* This implements E+(x). *)
    fun lookupVar (E : deep_env) (x, tau) =
      Var.Ctx.lookup (#vars E) x
      handle Var.Ctx.Absent => 
        check (`x, tau)
          <: E ** []

    fun lookupMeta (E : deep_env) x = 
      Metavar.Ctx.lookup (#metas E) x
  in
    fun variable (x, tau) (E ** L) = 
      let
        val m <: E' ** L' = lookupVar E (x, tau)
      in
        m <: E' ** (L' @ L)
      end

    fun metavariable (x, rs, ms, tau) (E ** L) =
      let
        val (us, xs) \ n <: E' ** L' = lookupMeta E x
        val F =
          {vars = ListPair.foldrEq (fn (x, m, rho) => Var.Ctx.insert rho x (Env.forceTerm (E ** L) m)) Var.Ctx.empty (xs, ms),
           syms = ListPair.foldrEq (fn (u, (r, _), rho) => Sym.Ctx.insert rho u (Env.forceParam (E ** L) r)) Sym.Ctx.empty (us, rs)}
        val L'' = L @ [F]
      in
        n <: E' ** (L' @ L'')
      end
  end
end

functor NewMachine () = struct end

(* 
functor NewMachine (Sig : MINI_SIGNATURE) :
sig
  type sign = Sig.sign
  type abt = RedPrlAbt.abt
  type 'a machine

  datatype stability = 
     CUBICAL
   | NOMINAL

  datatype blocker =
     VAR of RedPrlAbt.variable
   | METAVAR of RedPrlAbt.metavariable

  exception Neutral of blocker
  exception Unstable
  exception Final

  val init : abt -> abt machine
  val step : sign -> stability -> abt machine -> abt machine
end = 
struct
  structure Tm = RedPrlAbt
  structure Syn = Syntax
  structure SymSet = SplaySet (structure Elem = Sym.Ord)
  
  type sign = Sig.sign
  open Closure

  fun @@ (f, x) = f x
  infixr @@

  infix 6 <:
  infix 3 ||


  open Tm infix 7 $ $$ $# infix 6 \
  structure O = RedPrlOpData
  structure P = struct open RedPrlParameterTerm RedPrlSortData end

  datatype hole = HOLE
  datatype continuation =
     APP of hole * abt
   | HCOM of symbol O.dir * hole * abt * (symbol O.equation * (symbol * abt)) list
   | COE of symbol O.dir * (symbol * hole) * abt
   | FST of hole
   | SND of hole
   | W_IF of (variable * abt) * hole * abt * abt
   | IF of hole * abt * abt

  type frame = continuation closure
  type stack = frame list
  type bound_syms = SymSet.set

  datatype 'a machine = || of 'a closure * (bound_syms * stack)


  datatype stability = 
     CUBICAL
   | NOMINAL

  datatype blocker =
     VAR of variable
   | METAVAR of metavariable

  exception Neutral of blocker
  exception Unstable
  exception Final

  val todo = Fail "TODO"
  fun ?e = raise e

  val emptyEnv = 
    (Metavar.Ctx.empty,
     Var.Ctx.empty,
     Sym.Ctx.empty)

  fun lookupSym psi x = 
    Sym.Ctx.lookup psi x
    handle Sym.Ctx.Absent => P.ret x

  fun readParam psi : param -> param = 
    P.bind (lookupSym psi)

  fun insertVar x cl (mrho, rho, psi) = 
    (mrho, Var.Ctx.insert rho x cl, psi)

  fun insertMeta meta bcl (mrho, rho, psi) = 
    (Metavar.Ctx.insert mrho meta bcl, rho, psi)

  fun insertSym u r (mrho, rho, psi) = 
    (mrho, rho, Sym.Ctx.insert psi u r)

  (* Feel free to try and make more efficient *)
  (* fun forceClosure (tm <: (env as (mrho, rho, psi))) = 
    case infer tm of
       (`x, _) =>
         (case Var.Ctx.find rho x of 
             SOME cl => forceClosure cl
           | NONE => tm)
     | (x $# (ps, ms), tau) => 
         (case Metavar.Ctx.find mrho x of 
             SOME ((us, xs) \ cl) =>
               let
                 val m' = forceClosure cl
                 val rho' = ListPair.foldl (fn (x, n, rho) => Var.Ctx.insert rho x (n <: env)) rho (xs, ms)
                 val psi' = ListPair.foldl (fn (u, (r, _), psi) => Sym.Ctx.insert psi u (readParam psi r)) psi (us, ps)
               in
                 forceClosure (m' <: (mrho, rho', psi'))
               end
           | NONE =>
               let
                 val ps' = List.map (fn (r, sigma) => (readParam psi r, sigma)) ps
                 val ms' = List.map (forceClosure o (fn m => m <: env)) ms
               in
                 check (x $# (ps', ms'), tau)
               end)
     | (theta $ es, _) =>
         let
           val theta' = Tm.O.map (lookupSym psi) theta
           val es' = List.map (mapBind (forceClosure o (fn m => m <: env))) es
         in
           theta' $$ es'
         end *)


  (* Is it safe to observe the identity of a dimension? *)
  fun dimensionSafeToObserve syms r = 
    case r of 
       P.VAR x => SymSet.member syms x
     | _ => true

  fun dimensionsEqual stability syms (_, _, psi) (r1, r2) = 
    let
      val r1' = readParam psi r1
      val r2' = readParam psi r2
    in
      (* If two dimensions are equal, then no substitution can ever change that. *)
      if P.eq Sym.eq (r1', r2') then 
        true
      else
        (* On the other hand, if they are not equal, this observation may not commute with cubical substitutions. *)
        case stability of 
           (* An observation of apartness is stable under permutations. *)
           NOMINAL => false
           (* An observation of apartness is only stable if one of the compared dimensions is bound. *)
         | CUBICAL =>
             if dimensionSafeToObserve syms r1' orelse dimensionSafeToObserve syms r2' then 
               false 
             else
               raise Unstable
    end

  fun findTrueEquationIndex stability syms env = 
    let
      fun aux i [] = NONE
        | aux i ((r,r') :: eqs) =
          if dimensionsEqual stability syms env (r, r') then 
            SOME i
          else 
            aux (i + 1) eqs
    in
      aux 0
    end

  fun stepView sign stability tau = ?todo
    (* fn `x <: (mrho, rho, psi) || stk =>
       (Var.Ctx.lookup rho x || stk
        handle Var.Ctx.Absent => raise Neutral (VAR x))
     | (tm as (_ $# _)) <: env || stk =>
         forceClosure (check (tm, tau) <: env) <: env || stk

     | O.POLY (O.CUST (opid, ps, _)) $ args <: env || stk => 
       let
         val (mrho, rho, psi) = env
         val entry as {state,...} = Sig.lookup sign opid
         val term = Sig.extract state
         val (mrho', psi') = Sig.applyCustomOperator entry (List.map #1 ps) args
         val mrho'' = Metavar.Ctx.union mrho (Metavar.Ctx.map ((fn (us,xs) \ m => (us,xs) \ (m <: env)) o outb) mrho') (fn _ => raise Fail "Duplicated metavariables")
         val psi'' = raise Match
       in
         term <: (mrho'', rho, psi'') || stk
       end

     | O.POLY (O.COE dir) $ [([u], _) \ a, _ \ coercee] <: env || (syms, stk) =>
       a <: env || (SymSet.insert syms u, COE (dir, (u, HOLE), coercee) <: env :: stk)
     | O.POLY (O.HCOM (dir, eqs)) $ (_ \ a :: _ \ cap :: tubes) <: env || (syms, stk) =>
       a <: env || (syms, HCOM (dir, HOLE, cap, ListPair.map (fn (eq, ([u],_) \ n) => (eq, (u,n))) (eqs, tubes)) <: env :: stk)

     | O.POLY (O.COM ((r,r'), eqs)) $ (([u],_) \ a :: _ \ cap :: tubes) <: env || stk => 
       let
         fun makeTube (eq, ([v],_) \ n) = 
           (eq, (v, Syn.into @@ Syn.COE
             {dir = (P.ret v, r'),
              ty = (v, a),
              coercee = n}))

         val hcom = 
           Syn.into @@ Syn.HCOM
             {dir = (r, r'),
              ty = a,
              cap = Syn.into @@ Syn.COE
                {dir = (r, r'),
                 ty = (u, a),
                 coercee = cap},
              tubes = ListPair.map makeTube (eqs, tubes)}

          val env' = insertSym u (readParam (#3 env) r') env
       in
         hcom <: env' || stk
       end

     | O.POLY (O.FCOM (dir, eqs)) $ (_ \ cap :: tubes) <: env || (syms, stk) =>
       if dimensionsEqual stability syms env dir then 
         cap <: env || (syms, stk)
       (* TODO: be less conservative, use 'syms' as a weapon *)
       else
         (case (findTrueEquationIndex stability syms env eqs, stk) of 
             (SOME i, _) =>
               let
                 val (_, r') = dir
                 val ([u], _) \ n = List.nth (tubes, i)
                 val env' = insertSym u (readParam (#3 env) r') env
               in
                 n <: env' || (syms, stk)
               end
           | (NONE, []) => raise Final
           | (NONE, W_IF ((x,a), HOLE, mt, mf) <: env' :: stk) => ?todo
           | _ => ?todo)

     (* TODO: fcom stepping rules *)

     | O.MONO O.AP $ [_ \ m, _ \ n] <: env || (syms, stk) =>
       m <: env || (syms, APP (HOLE, n) <: env :: stk)
     | O.MONO O.LAM $ [(_, [x]) \ mx] <: (mrho, rho, psi) || (syms, APP (HOLE, n) <: env' :: stk) =>
       mx <: (mrho, Var.Ctx.insert rho x (n <: env'), psi) || (syms, stk)

     | O.MONO O.DFUN $ [_ \ a, (_,[x]) \ bx] <: env || (us, COE ((r,r'), (u, HOLE), coercee) <: env' :: stk) =>
       let
         val metaX = Metavar.named "X"
         val metaY = Metavar.named "Y"
         val metaZ = Metavar.named "Z"
         val xtm = check (`x, O.EXP)
         val uprm = (P.ret u, P.DIM)
         val y = Var.named "y"
         val ytm = check (`y, O.EXP)

         val lam =
           Syn.into @@ Syn.LAM (x, 
            Syn.into @@ Syn.COE
              {dir = (r,r'),
               ty = (u, check (metaX $# ([uprm], [xtm]), O.EXP)),
               coercee = 
                 Syn.into @@ Syn.AP
                   (coercee,
                    Syn.into @@ Syn.COE
                      {dir = (r', r),
                       ty = (u, check (metaY $# ([uprm],[]), O.EXP)),
                       coercee = check (metaY $# ([uprm],[]), O.EXP)})})

         val metaYCl = ([u], []) \ (a <: env)

         val coeyCl = 
           Syn.into 
             (Syn.COE
               {dir = (r', P.ret u),
                ty = (u, check (metaZ $# ([uprm],[]), O.EXP)),
                coercee = ytm})
             <: insertMeta metaZ (([u],[]) \ (a <: env)) env'

         val metaXCl = ([u], [y]) \ (bx <: insertVar x coeyCl env)
         val env'' = 
           insertMeta metaY metaYCl @@ 
             insertMeta metaX metaXCl env'
       in
         lam <: env'' || (SymSet.remove us u, stk)
       end

     | O.MONO O.DFUN $ [_ \ a, (_,[x]) \ bx] <: env || (syms, HCOM (dir, HOLE, cap, tubes) <: env' :: stk) =>
       let
         val metaX = Metavar.named "X"
         val env'' = insertMeta metaX (([],[x]) \ (bx <: env)) env'
         val xtm = check (`x, O.EXP)
         val hcom =
           Syn.into @@ Syn.HCOM 
             {dir = dir,
              ty = check (metaX $# ([],[xtm]), O.EXP),
              cap = Syn.into @@ Syn.AP (cap, xtm),
              tubes = List.map (fn (eq, (u, n)) => (eq, (u, Syn.into @@ Syn.AP (n, xtm)))) tubes}

         val lam = Syn.into @@ Syn.LAM (x, hcom)
       in
         lam <: env'' || (syms, stk)
       end

     | O.MONO O.FST $ [_ \ m] <: env || (syms, stk) =>
        m <: env || (syms, FST HOLE <: env :: stk)
     | O.MONO O.SND $ [_ \ m] <: env || (syms, stk) => 
        m <: env || (syms, SND HOLE <: env :: stk)

     | O.MONO O.PAIR $ [_ \ m1, _] <: env || (syms, FST HOLE <: _ :: stk) => 
        m1 <: env || (syms, stk)
     | O.MONO O.PAIR $ [_, _ \ m2] <: env || (syms, SND HOLE <: _ :: stk) =>
        m2 <: env || (syms, stk)
    
     | O.MONO O.DPROD $ [_ \ a, (_,[x]) \ bx] <: env || (syms, COE ((r,r'), (u, HOLE), coercee) <: env' :: stk) => 
       let
         val metaX = Metavar.named "X"
         val metaY = Metavar.named "Y"
         val uprm = (P.ret u, P.DIM)
         val proj1 =
           Syn.into @@ Syn.COE
             {dir = (r, r'),
              ty = (u, check (metaX $# ([uprm], []), O.EXP)),
              coercee = Syn.into @@ Syn.FST coercee}
         fun proj2 s = 
           Syn.into @@ Syn.COE
             {dir = (r, s),
              ty = (u, check (metaY $# ([uprm], []), O.EXP)),
              coercee = Syn.into @@ Syn.SND coercee}

         val metaXCl = ([u],[]) \ (a <: env)
         val metaYCl = ([u],[]) \ (bx <: insertVar x (proj2 (P.ret u) <: insertMeta metaX metaXCl env) env)
         val env'' = insertMeta metaX metaXCl (insertMeta metaY metaYCl env')

         val pair = Syn.into @@ Syn.PAIR (proj1, proj2 r')
       in
         pair <: env'' || (SymSet.remove syms u, stk)
       end

     | O.MONO O.DPROD $ [_ \ a, (_,[x]) \ bx] <: env || (syms, HCOM ((r,r'), HOLE, cap, tubes) <: env' :: stk) => 
       let
         val metaX = Metavar.named "X"
         val metaY = Metavar.named "Y"
         val xtm = check (`x, O.EXP)

         fun proj1 s = 
           Syn.into @@ Syn.HCOM 
             {dir = (r, s),
              ty = check (metaX $# ([],[]), O.EXP),
              cap = Syn.into @@ Syn.FST cap,
              tubes = List.map (fn (eq, (u, n)) => (eq, (u, Syn.into @@ Syn.FST n))) tubes}

         val v = Sym.named "v"

         val proj2 = 
           Syn.into @@ Syn.COM
             {dir = (r, r'),
              ty = (v, check (metaY $# ([(P.ret v, P.DIM)], []), O.EXP)),
              cap = Syn.into @@ Syn.SND cap,
              tubes = List.map (fn (eq, (u, n)) => (eq, (u, Syn.into @@ Syn.SND n))) tubes}

         val pair = Syn.into @@ Syn.PAIR (proj1 r', proj2)

         val env'' = insertMeta metaX (([],[]) \ (a <: env)) env'
         val metaYCl = ([v],[]) \ (bx <: (insertVar x (proj1 (P.ret v) <: env'') env))
         val env''' = insertMeta metaY metaYCl env''
       in
         pair <: env''' || (syms, stk)
       end


     | _ => raise Final *)

  fun step sign stability (tm <: env || stk) =
    let
      val (view, tau) = infer tm
    in
      stepView sign stability tau (view <: env || stk)
    end

  fun init tm = 
    tm <: Env.empty || (SymSet.empty, [])
end *)