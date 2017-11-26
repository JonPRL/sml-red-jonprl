functor RefinerCompositionKit (Sig : MINI_SIGNATURE) =
struct
  structure Kit = RefinerKit (Sig)
  open RedPrlAbt Kit

  type sign = Sig.sign
  type rule = (int -> Sym.t) -> Lcf.jdg Lcf.tactic
  type catjdg = AJ.jdg
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
    val restrict : (abt * abt) list -> (abt -> abt) option
  end
  =
  struct
    (* precondition: all term in equations are of sort `DIM` *)
    fun restrict' [] (f : abt -> abt) = SOME f
      | restrict' ((r1, r2) :: eqs) (f : abt -> abt) = 
          (case (Syn.out r1, Syn.out r2) of
              (Syn.DIM0, Syn.DIM0) => restrict' eqs f
            | (Syn.DIM0, Syn.DIM1) => NONE
            | (Syn.DIM1, Syn.DIM1) => restrict' eqs f
            | (Syn.DIM1, Syn.DIM0) => NONE
            | (Syn.VAR (v1, _), _) => if Abt.eq (r1, r2) then restrict' eqs f else substAndRestrict' (r2, v1) eqs f
            | (Syn.META (v1, _), _) => if Abt.eq (r1, r2) then restrict' eqs f else substMetaAndRestrict' (r2, v1) eqs f
            | (_, Syn.VAR (v2, _)) => substAndRestrict' (r1, v2) eqs f
            | (_, Syn.META (v2, _)) => substMetaAndRestrict' (r1, v2) eqs f)

    and substMetaAndRestrict' (r, v) eqs f =
        let
          val abs = abtToAbs r
        in
          restrict'
            (List.map (fn (r1, r2) => (substMetavar (abs, v) r1, substMetavar (abs, v) r2)) eqs)
            (substMetavar (abs, v) o f)
        end

    and substAndRestrict' rv eqs f =
          restrict'
            (List.map (fn (r, r') => (substVar rv r, substVar rv r')) eqs)
            (substVar rv o f)

    fun restrict eqs = restrict' eqs (fn x => x)
  end
  (* adding some helper functions *)
  structure Restriction =
  struct
    open Restriction

    fun restrictJdg eqs jdg = Option.map (fn f => Seq.map f jdg) (restrict eqs)

    fun makeEq eqs H ((m, n), (ty, l)) =
      Option.map
        (fn f => makeEqWith f H ((m, n), (ty, l)))
        (restrict eqs)

    fun makeEqIfDifferent eqs H ((m, n), (ty, l)) =
      Option.mapPartial
        (fn f =>
          if Abt.eq (f m, f n) then NONE
          else SOME @@ makeEqWith f H ((m, n), (ty, l)))
        (restrict eqs)

    fun makeMem eqs H (m, (ty, l)) =
      makeEq eqs H ((m, m), (ty, l))

    fun makeEqType eqs H ((a, b), l, k) =
      Option.map
        (fn f => makeEqTypeWith f H ((a, b), l, k))
        (restrict eqs)

    fun makeEqTypeIfDifferent eqs H ((a, b), l, k) =
      Option.mapPartial
        (fn f =>
          if Abt.eq (f a, f b) then NONE
          else SOME @@ makeEqTypeWith f H ((a, b), l, k))
        (restrict eqs)

    fun makeTrue eqs default H (a, l) =
      case restrict eqs of
        NONE => (NONE, default)
      | SOME f =>
          let
            val (goal, hole) = makeTrueWith f H (a, l)
          in
            (SOME goal, hole)
          end
  end

  (* code shared by Com, HCom and FCom. *)
  structure ComKit =
  struct
    (* todo: optimizing the restriction process even further. *)
    (* todo: pre-restrict r=0, r=1, 0=r and 1=r. *)
    (* todo: try to reduce substitution. *)

    (* Produce the list of goals requiring that tube aspects agree with each other.
         forall i <= j.
           N_i = P_j in A [Psi, y | r_i = r_i', r_j = r_j']
     *)
    fun alphaRenameTubes w = List.map (fn (eq, (u, tube)) => (eq, substVar (VarKit.toDim w, u) tube))
    fun enumInterExceptDiag f =
      let
        fun enum ([], []) = []
          | enum ((t0 :: ts0), (_ :: ts1)) = List.mapPartial (fn t1 => f (t0, t1)) ts1 :: enum (ts0, ts1)
          | enum _ = E.raiseError @@ E.IMPOSSIBLE @@ Fpp.text "enumInterExceptDiag: inputs are of different lengths"
      in
        List.concat o enum
      end

    local
      fun genTubeGoals' (H : AJ.jdg Hyps.telescope) ((tubes0, tubes1), (ty, l)) =
        ListPairUtil.mapPartialEq
          (fn ((eq, t0), (_, t1)) => Restriction.makeEq [eq] H ((t0, t1), (ty, l)))
          (tubes0, tubes1)

      fun genInterTubeGoalsExceptDiag' (H : AJ.jdg Hyps.telescope) ((tubes0, tubes1), (ty, l)) =
        enumInterExceptDiag
          (fn ((eq0, t0), (eq1, t1)) => Restriction.makeEqIfDifferent [eq0, eq1] H ((t0, t1), (ty, l)))
          (tubes0, tubes1)
    in
      fun genInterTubeGoals (H : AJ.jdg Hyps.telescope) w ((tubes0, tubes1), (ty, l)) =
        let
          val tubes0 = alphaRenameTubes w tubes0
          val tubes1 = alphaRenameTubes w tubes1

          val goalsOnDiag = genTubeGoals' (H @> (w, AJ.TERM O.DIM)) ((tubes0, tubes1), (ty, l))
          val goalsNotOnDiag = genInterTubeGoalsExceptDiag' (H @> (w, AJ.TERM O.DIM)) ((tubes0, tubes1), (ty, l))
        in
          goalsOnDiag @ goalsNotOnDiag
        end
    end

    (* Produce the list of goals requiring that tube aspects agree with the cap.
         forall i.
           M = N_i<r/y> in A [Psi | r_i = r_i']
     *)
    fun genCapTubeGoalsIfDifferent H ((cap, (r, tubes)), (ty, l)) =
      List.mapPartial
        (fn (eq, (u, tube)) =>
          Restriction.makeEqIfDifferent [eq] H ((cap, substVar (r, u) tube), (ty, l)))
        tubes

    (* Note that this does not check whether the 'ty' is a base type.
     * It's caller's responsibility to check whether the type 'ty'
     * recognizes FCOM as values. *)
    fun genEqFComGoals H w (args0, args1) (ty, l) =
      let
        val {dir=dir0, cap=cap0, tubes=tubes0 : abt Syn.tube list} = args0
        val {dir=dir1, cap=cap1, tubes=tubes1 : abt Syn.tube list} = args1
        val () = Assert.dirEq "genFComGoals" (dir0, dir1)
        val eqs0 = List.map #1 tubes0
        val eqs1 = List.map #1 tubes1
        val _ = Assert.equationsEq "genFComGoals equations" (eqs0, eqs1)
        val _ = Assert.tautologicalEquations "genFComGoals tautology checking" eqs0

        val goalCap = makeEq H ((cap0, cap1), (ty, l))
      in
           goalCap
        :: genInterTubeGoals H w ((tubes0, tubes1), (ty, l))
         @ genCapTubeGoalsIfDifferent H ((cap0, (#1 dir0, tubes0)), (ty, l))
      end
  end

  structure HCom =
  struct
    fun Eq alpha jdg =
      let
        val _ = RedPrlLog.trace "HCom.Eq"
        val H >> AJ.EQ ((lhs, rhs), (ty, l)) = jdg
        val k = K.HCOM
        (* these operations could be expensive *)
        val Syn.HCOM {dir=dir0, ty=ty0, cap=cap0, tubes=tubes0} = Syn.out lhs
        val Syn.HCOM {dir=dir1, ty=ty1, cap=cap1, tubes=tubes1} = Syn.out rhs
        val () = Assert.dirEq "HCom.Eq direction" (dir0, dir1)

        (* equations *)
        val eqs0 = List.map #1 tubes0
        val eqs1 = List.map #1 tubes1
        val _ = Assert.equationsEq "HCom.Eq equations" (eqs0, eqs1)
        val _ = Assert.tautologicalEquations "HCom.Eq tautology checking" eqs0

        (* type *)
        val goalTy = makeEqType H ((ty0, ty1), l, k)
        val goalTy0 = makeSubTypeIfDifferent H ((ty0, ty), l) (* (ty0, l, k) is proved *)

        (* cap *)
        val goalCap = makeEq H ((cap0, cap1), (ty0, l))

        val w = alpha 0
      in
        |>: goalCap
         >:+ ComKit.genInterTubeGoals H w ((tubes0, tubes1), (ty0, l))
         >:+ ComKit.genCapTubeGoalsIfDifferent H ((cap0, (#1 dir0, tubes0)), (ty0, l))
         >:? goalTy0 >: goalTy
        #> (H, trivial)
      end

    fun EqCapL alpha jdg =
      let
        val _ = RedPrlLog.trace "HCom.EqCapL"
        val H >> AJ.EQ ((hcom, other), (ty, l)) = jdg
        val k = K.HCOM
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r, r'), ty=ty0, cap, tubes} = Syn.out hcom
        val () = Assert.alphaEq' "HCom.EqCapL source and target of direction" (r, r')

        (* equations *)
        val _ = Assert.tautologicalEquations "HCom.EqCapL tautology checking" (List.map #1 tubes)

        (* type *)
        val goalTy0 = makeEqType H ((ty0, ty), l, k)

        (* eq *)
        val goalEq = makeEq H ((cap, other), (ty, l))

        val w = alpha 0
      in
        |>: goalEq
         >:+ ComKit.genInterTubeGoals H w ((tubes, tubes), (ty0, l))
         >:+ ComKit.genCapTubeGoalsIfDifferent H ((cap, (r, tubes)), (ty0, l))
         >: goalTy0
        #> (H, trivial)
      end

    (* Search for the first satisfied equation in an hcom. *)
    fun EqTubeL alpha jdg =
      let
        val _ = RedPrlLog.trace "HCom.EqTubeL"
        val H >> AJ.EQ ((hcom, other), (ty, l)) = jdg
        val k = K.HCOM
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r, r'), ty=ty0, cap, tubes} = Syn.out hcom

        (* equations. they must be tautological because one of them is true. *)
        val (_, (u, tube)) = Option.valOf (List.find (fn (eq, _) => Abt.eq eq) tubes)

        (* type *)
        val goalTy0 = makeEqType H ((ty0, ty), l, k)

        (* cap *)
        (* the cap-tube adjacency premise guarantees that [cap] is in [ty0],
         * and thus there is nothing to prove! Yay! *)

        (* eq *)
        (* the tube-tube adjacency premise guarantees that this particular tube
         * is unconditionally in [ty], and thus alpha-equivalence is sufficient. *)
        val goalEq = makeEqIfDifferent H ((substVar (r', u) tube, other), (ty0, l))

        val w = alpha 0
      in
        |>:? goalEq
         >:+ ComKit.genInterTubeGoals H w ((tubes, tubes), (ty0, l))
         >:+ ComKit.genCapTubeGoalsIfDifferent H ((cap, (r, tubes)), (ty0, l))
         >: goalTy0
        #> (H, trivial)
      end
  end
end
