structure MetalanguageSyntax : METALANGUAGE_SYNTAX =
struct
  structure Var = AbtSymbol ()
  structure Meta = AbtSymbol ()

  structure Tm = RedPrlAbt
  type oterm = Tm.abt
  type osym = Tm.symbol
  type rexpr = string RedExpr.expr
  type ovalence = Tm.valence

  type mlvar = Var.t
  type meta = Meta.t

  datatype osort = OSORT of Tm.sort | PSORT of Tm.psort

  val freshVar = Var.new

  structure Ctx : DICT = Var.Ctx

  datatype ('v, 'a) scope = \ of 'v * 'a
  infix \

  datatype mltype =
     UNIT
   | ARR of mltype * mltype
   | PROD of mltype * mltype
   | OTERM
   | THEOREM
   | META of meta

  type rule_name = string

  type ('s, 'o, 't) omatch_clause = (('s * ovalence) list, 'o * 't) scope

  datatype ('v, 's, 'o, 'a) mltermf =
     VAR of 'v
   | LET of 'a * ('v, 'a) scope
   | SEQ_FORK of 'a * 'a list
   | FUN of ('v, 'a) scope
   | APP of 'a * 'a
   | PAIR of 'a * 'a
   | FST
   | SND
   | QUOTE of 'o | GOAL
   | REFINE of rule_name
   | TRY of 'a * 'a
   | PUSH of (('s * osort) list, 'a) scope
   | NIL
   | PROVE of 'a * 'a
   | OMATCH of 'a * ('s, 'o, 'a) omatch_clause list
   | PRINT of 'a
   | EXACT of 'a

  type annotation = Pos.t option
  datatype ('v, 's, 'o) mlterm = :@ of ('v, 's, 'o, ('v, 's, 'o) mlterm) mltermf * annotation
  infix :@

  type mlterm_ = (mlvar, Tm.symbol, Tm.abt) mlterm
  type src_mlterm = (string, string, rexpr) mlterm

  exception todo
  fun ?e = raise e

  (* TODO: freshen *)
  fun unscope (x \ t) = (x, t)
  fun scope (x, t) = x \ t
  fun oscope (us, tm) = us \ tm


  structure Resolver =
  struct
    structure Names = StringListDict

    type ostate = RedExpr.state

    type state =
      {ostate: ostate,
       mlenv: mlvar Names.dict}

    fun addMlvar {ostate, mlenv} x x' =
      {ostate = ostate,
       mlenv = Names.insert mlenv x x'}

    fun addObjectNames {ostate = {metactx, symctx, varctx, metaenv, symenv, varenv}, mlenv} (xs : (string * osort) list) (xs' : (Tm.symbol * osort) list) : state =
      {mlenv = mlenv,
       ostate = 
         {metactx = metactx,
          symctx = List.foldl (fn ((x, PSORT sigma), r) => Tm.Sym.Ctx.insert r x sigma | (_, r) => r) symctx xs',
          varctx = List.foldl (fn ((x, OSORT tau), r) => Tm.Var.Ctx.insert r x tau | (_, r) => r) varctx xs',
          metaenv = metaenv,
          symenv = ListPair.foldl (fn ((x, _), (x', PSORT _), r) => Names.insert r x x' | (_, _, r) => r) symenv (xs, xs'),
          varenv = ListPair.foldl (fn ((x, _), (x', OSORT _), r) => Names.insert r x x' | (_, _, r) => r) varenv (xs, xs')}}

    fun addMetas {ostate = {metactx, symctx, varctx, metaenv, symenv, varenv}, mlenv} metas metas' : state =
      {mlenv = mlenv,
       ostate = 
         {metactx = List.foldl (fn ((x, vl), r) => Tm.Metavar.Ctx.insert r x vl) metactx metas',
          symctx = symctx,
          varctx = varctx,
          metaenv = ListPair.foldl (fn ((x, _), (x', _), r) => Names.insert r x x') metaenv (metas, metas'),
          symenv = symenv,
          varenv = varenv}}

    fun mlvar (state : state) =
      Names.lookup (#mlenv state)

    fun resolveAux (state : state) : (string, string, rexpr) mlterm -> mlterm_ =
      fn VAR x :@ ann => VAR (mlvar state x) :@ ann
       | LET (t, sc) :@ ann => LET (resolveAux state t, resolveAuxScope state sc) :@ ann
       | SEQ_FORK (t, ts) :@ ann => SEQ_FORK (resolveAux state t, List.map (resolveAux state) ts) :@ ann
       | FUN sc :@ ann => FUN (resolveAuxScope state sc) :@ ann
       | APP (t1, t2) :@ ann => APP (resolveAux state t1, resolveAux state t2) :@ ann
       | PAIR (t1, t2) :@ ann => PAIR (resolveAux state t1, resolveAux state t2) :@ ann
       | FST :@ ann => FST :@ ann
       | SND :@ ann => SND :@ ann
       | QUOTE rexpr :@ ann => QUOTE (RedExpr.reader (#ostate state) rexpr) :@ ann
       | GOAL :@ ann => GOAL :@ ann
       | REFINE ruleName :@ ann => REFINE ruleName :@ ann
       | TRY (t1, t2) :@ ann => TRY (resolveAux state t1, resolveAux state t2) :@ ann
       | PUSH sc :@ ann => PUSH (resolveAuxObjScope state sc) :@ ann
       | NIL :@ ann => NIL :@ ann
       | PROVE (t1, t2) :@ ann => PROVE (resolveAux state t1, resolveAux state t2) :@ ann
       | OMATCH (scrutinee, clauses) :@ ann => OMATCH (resolveAux state scrutinee, List.map (resolveAuxObjMatchClause state) clauses) :@ ann
       | PRINT t :@ ann => PRINT (resolveAux state t) :@ ann
       | EXACT t :@ ann => EXACT (resolveAux state t) :@ ann

    and resolveAuxScope (state : state) (x \ tx) =
      let
        val x' = Var.named x
        val state' = addMlvar state x x'
      in
        x' \ resolveAux state' tx
      end

    and resolveAuxObjScope (state : state) ((xs : (string * osort) list) \ txs) =
      let
        val xs' = List.map (fn (x, osort) => (Tm.Sym.named x, osort)) xs
        val state' = addObjectNames state xs xs'
      in
        xs' \ resolveAux state' txs
      end

    and resolveAuxObjMatchClause (state : state) (metas \ (rexpr, t)) =
      let
        val metas' = List.map (fn (x, vl) => (Tm.Metavar.named x, vl)) metas
        val state' = addMetas state metas metas'
      in
        metas' \ (RedExpr.reader (#ostate state') rexpr, resolveAux state' t)
      end

    val resolve : (string, string, rexpr) mlterm -> mlterm_ =
      resolveAux
        {ostate =
          {metactx = Tm.Metavar.Ctx.empty,
           varctx = Tm.Var.Ctx.empty,
           symctx = Tm.Sym.Ctx.empty,
           metaenv = Names.empty,
           symenv = Names.empty,
           varenv = Names.empty},
        mlenv = Names.empty}
    end

  structure Ast = 
  struct
    fun fn_ (x, t) pos : src_mlterm = 
      FUN (x \ t) :@ pos

    fun let_ (t, (x, tx)) pos = 
      LET (t, x \ tx) :@ pos

    fun push (xs : (string * osort) list, t : src_mlterm) pos : src_mlterm = 
      PUSH (xs \ t) :@ pos
  end

end