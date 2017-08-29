functor RefinerCompositionKit (Sig : MINI_SIGNATURE) =
struct
  structure Kit = RefinerKit (Sig)
  open RedPrlAbt Kit

  type sign = Sig.sign
  type rule = (int -> Sym.t) -> Lcf.jdg Lcf.tactic
  type catjdg = CJ.jdg
  type opid = Sig.opid

  infixr @@
  infix 1 || #>
  infix 2 >> >: >:? >:+ $$ $# // \ @>
  infix orelse_

  structure Restriction :
  sig
    (* This structure used to provide functions that automate the
       restriction judgement rules given in "Dependent Cubical
       Realizability", page 46.

       On 2017/06/14, favonia implemented a function to handle
       all cases.
     *)

    (* Restrict a judgement (as the goal) by a list of equations.
     * Returns NONE if the resulting judgement is vacuously true.
     *)
    val restrict : (param * param) list -> (abt -> abt) option
  end
  =
  struct
    (* A helper function which does substitution in a parameter. *)
    fun substSymInParam (r, v) = P.bind (fn u => if Sym.eq (u, v) then r else P.ret u)

    (* precondition: all parameters in equations are of sorts `DIM` *)
    fun restrict' [] f = SOME f
      | restrict' ((P.APP d1, P.APP d2) :: eqs) f =
          (* The following line is correct because we only have constants
           * (DIM0 and DIM1). If in the future we want to have connections
           * or other stuff, then a real unification algorithm might be needed.
           *)
          if P.Sig.eq (fn _ => true) (d1, d2) then restrict' eqs f else NONE
      | restrict' ((r1 as P.VAR v1, r2) :: eqs) f =
          if P.eq Sym.eq (r1, r2) then restrict' eqs f else substAndRestrict' (r2, v1) eqs f
      | restrict' ((r1, P.VAR v2) :: eqs) f =
          substAndRestrict' (r1, v2) eqs f

    and substAndRestrict' rv eqs f =
          restrict'
            (List.map (fn (r, r') => (substSymInParam rv r, substSymInParam rv r')) eqs)
          (substSymbol rv o f)

    fun restrict eqs = restrict' eqs (fn x => x)
  end
  (* adding some helper functions *)
  structure Restriction =
  struct
    open Restriction

    fun restrictJdg eqs jdg = Option.map (fn f => Seq.map f jdg) (restrict eqs)

    local
      fun makeEq' f (I, H) ((m, n), (ty, l, k)) =
        makeGoal' @@ Seq.map f @@ (I, H) >> CJ.EQ ((m, n), (ty, l, k))
    in
      fun makeEq eqs (I, H) ((m, n), (ty, l, k)) =
        Option.map
          (fn f => makeEq' f (I, H) ((m, n), (ty, l, k)))
          (restrict eqs)

      fun makeEqIfDifferent eqs (I, H) ((m, n), (ty, l, k)) =
        Option.mapPartial
          (fn f =>
            if Abt.eq (f m, f n) then NONE
            else SOME @@ makeEq' f (I, H) ((m, n), (ty, l, k)))
          (restrict eqs)
    end
  end

  (* code shared by Com, HCom and FCom. *)
  structure ComKit =
  struct
    (* todo: optimizing the restriction process even further. *)
    (* todo: pre-restrict r=0, r=1, 0=r and 1=r, and open-reduce everything first. *)
    (* todo: do alpha-renaming only once. *)
    (* todo: try to reduce substitution. *)

    (* Produce the list of goals requiring that tube aspects agree with each other.
         forall i <= j.
           N_i = P_j in A [Psi, y | r_i = r_i', r_j = r_j']
     *)
    fun genInterTubeGoals (I, H) w (ty, l, k) tubes0 tubes1 =
      let
        fun interTube (eq0, (u, tube0)) (eq1, (v, tube1)) =
          let
            val tube0 = substSymbol (P.ret w, u) tube0
            val tube1 = substSymbol (P.ret w, v) tube1
          in
            Restriction.makeEq [eq0, eq1] (I @ [(w,P.DIM)], H) ((tube0, tube1), (ty, l, k))
          end
        fun goTubePairs [] [] = []
          | goTubePairs (t0 :: ts0) (t1 :: ts1) =
              List.mapPartial (interTube t0) (t1 :: ts1) :: goTubePairs ts0 ts1
          | goTubePairs _ _ = raise
              E.error [Fpp.text "interTubeGoals: the tubes are of different lengths"]
      in
        List.concat (goTubePairs tubes0 tubes1)
      end

    (* Produce the list of goals requiring that tube aspects agree with the cap.
         forall i.
           M = N_i<r/y> in A [Psi | r_i = r_i']
     *)
    fun genCapTubeGoalsWhenDifferent (I, H) (ty, l, k) r cap tubes =
      let
        fun capTube (eq, (u, tube)) =
          Restriction.makeEqIfDifferent [eq] (I, H) ((cap, substSymbol (r, u) tube), (ty, l, k))
      in
        List.mapPartial capTube tubes
      end

    (* Note that this does not check whether the 'ty' is a base type.
     * It's caller's responsibility to check whether the type 'ty'
     * recognizes FCOM as values. *)
    fun EqHeterogeneousFComDelegate alpha (I, H) args0 args1 (tyCap, lCap, kCap) (tyTube, lTube, kTube) =
      let
        val {dir=(r0, r'0), cap=cap0, tubes=tubes0} = args0
        val {dir=(r1, r'1), cap=cap1, tubes=tubes1} = args1
        val () = Assert.paramEq "EqFComDelegator source of direction" (r0, r1)
        val () = Assert.paramEq "EqFComDelegator target of direction" (r'0, r'1)
        val eqs0 = List.map #1 tubes0
        val eqs1 = List.map #1 tubes1
        val _ = ListPair.mapEq (Assert.equationEq "EqFComDelegator equations") (eqs0, eqs1)
        val _ = Assert.tautologicalEquations "EqFComDelegator tautology checking" eqs0

        val goalCap = makeEq (I, H) ((cap0, cap1), (tyCap, lCap, kCap))

        val w = alpha 0
      in
        |>: goalCap
         >:+ genInterTubeGoals (I, H) w (tyTube, lTube, kTube) tubes0 tubes1
         >:+ genCapTubeGoalsWhenDifferent (I, H) (tyCap, NONE, K.top) r0 cap0 tubes0
        #> (I, H, trivial)
      end

    fun EqFComDelegate alpha (I, H) args0 args1 (ty, l, k) =
      EqHeterogeneousFComDelegate alpha (I, H) args0 args1 (ty, l, k) (ty, l, k)
  end

  structure HCom =
  struct
    fun Eq alpha jdg =
      let
        val _ = RedPrlLog.trace "HCom.Eq"
        val (I, H) >> CJ.EQ ((lhs, rhs), (ty, l, k)) = jdg
        val k = K.meet (k, K.HCOM)
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r0, r'0), ty=ty0, cap=cap0, tubes=tubes0} = Syn.out lhs
        val Syn.HCOM {dir=(r1, r'1), ty=ty1, cap=cap1, tubes=tubes1} = Syn.out rhs
        val () = Assert.paramEq "HCom.Eq source of direction" (r0, r1)
        val () = Assert.paramEq "HCom.Eq target of direction" (r'0, r'1)

        (* equations *)
        val eqs0 = List.map #1 tubes0
        val eqs1 = List.map #1 tubes1
        val _ = ListPair.mapEq (Assert.equationEq "HCom.Eq equations") (eqs0, eqs1)
        val _ = Assert.tautologicalEquations "HCom.Eq tautology checking" eqs0

        (* type *)
        val goalTy = makeEqTypeIfDifferent (I, H) ((ty0, ty1), l, k)
        val goalTy0 = makeEqTypeIfDifferent (I, H) ((ty0, ty), l, k)

        (* cap *)
        val goalCap = makeEq (I, H) ((cap0, cap1), (ty, l, k))

        val w = alpha 0
      in
        |>: goalCap
         >:+ ComKit.genInterTubeGoals (I, H) w (ty0, l, k) tubes0 tubes1
         >:+ ComKit.genCapTubeGoalsWhenDifferent (I, H) (ty, NONE, K.top) r0 cap0 tubes0
         >:? goalTy0 >:? goalTy
        #> (I, H, trivial)
      end

    fun EqCapL alpha jdg =
      let
        val _ = RedPrlLog.trace "HCom.EqCapL"
        val (I, H) >> CJ.EQ ((hcom, other), (ty, l, k)) = jdg
        val k = K.meet (k, K.HCOM)
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r, r'), ty=ty0, cap, tubes} = Syn.out hcom
        val () = Assert.paramEq "HCom.EqCapL source and target of direction" (r, r')

        (* equations *)
        val _ = Assert.tautologicalEquations "HCom.EqCapL tautology checking" (List.map #1 tubes)

        (* type *)
        val goalTy0 = makeEqTypeIfDifferent (I, H) ((ty0, ty), l, k)

        (* eq *)
        val goalEq = makeEq (I, H) ((cap, other), (ty, l, k))

        val w = alpha 0
      in
        |>: goalEq
         >:+ ComKit.genInterTubeGoals (I, H) w (ty, l, k) tubes tubes
         >:+ ComKit.genCapTubeGoalsWhenDifferent (I, H) (ty, NONE, K.top) r cap tubes
         >:? goalTy0
        #> (I, H, trivial)
      end

    (* Search for the first satisfied equation in an hcom. *)
    fun EqTubeL alpha jdg =
      let
        val _ = RedPrlLog.trace "HCom.EqTubeL"
        val (I, H) >> CJ.EQ ((hcom, other), (ty, l, k)) = jdg
        val k = K.meet (k, K.HCOM)
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r, r'), ty=ty0, cap, tubes} = Syn.out hcom

        (* equations. they must be tautological because one of them is true. *)
        val (_, (u, tube)) = Option.valOf (List.find (fn (eq, _) => P.eq Sym.eq eq) tubes)

        (* type *)
        (* the cap-tube adjacency premise guarantees that [ty] is a type
         * because one of the equations is true, and thus alpha-equivalence
         * is sufficient. *)
        val goalTy0 = makeEqTypeIfDifferent (I, H) ((ty0, ty), l, k)

        (* cap *)
        (* the cap-tube adjacency premise guarantees that [cap] is in [ty],
         * and thus there is nothing to prove! Yay! *)

        (* eq *)
        (* the tube-tube adjacency premise guarantees that this particular tube
         * is unconditionally in [ty], and thus alpha-equivalence is sufficient. *)
        val goalEq = makeEqIfDifferent (I, H) ((substSymbol (r', u) tube, other), (ty, l, k))

        val w = alpha 0
      in
        |>:? goalEq
         >:+ ComKit.genInterTubeGoals (I, H) w (ty, l, k) tubes tubes
         >:+ ComKit.genCapTubeGoalsWhenDifferent (I, H) (ty, NONE, K.top) r cap tubes
         >:? goalTy0
        #> (I, H, trivial)
      end
  end
end
