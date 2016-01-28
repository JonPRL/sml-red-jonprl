functor Elaborator (R : REFINER) : ELABORATOR =
struct
  structure Refiner = R
  structure T = R.Tacticals

  open Abt NominalLcfOperatorData OperatorData SortData
  infix $ \

  fun elaborateOpt m =
    case infer m of
         (OP_SOME _ $ [_ \ n], OPT _) => SOME n
       | (OP_NONE _ $ _, OPT _) => NONE
       | _ => raise Fail "Expected SOME or NONE"

  fun elaborateVec m =
    case #1 (infer m) of
         VEC_LIT _ $ es => List.map (fn (_ \ n) => n) es
       | _ => raise Fail "Expected vector argument"

  structure Env = SplayDict (structure Key = Variable)

  type env = Refiner.ntactic Env.dict

  fun probe (alpha : R.name_store) : R.name_store * int ref =
    let
      val mref = ref 0
      fun updateModulus i = if !mref < i then mref := i else ()
      fun beta i = (updateModulus (i + 1); alpha i)
    in
      (beta, mref)
    end

  fun prepend us =
    let
      val n = List.length us
    in
      fn alpha => fn i =>
        if i < n then
          List.nth (us, i)
        else
          alpha (i + n)
    end

  fun bite n alpha =
    fn i =>
      alpha (i + n)

  fun elaborate rho t =
    case #1 (infer t) of
         LCF ID $ _ => (fn _ => T.ID)
       | LCF (SEQ _) $ [_ \ t, (us, _) \ mt] =>
           elaborateMulti rho (elaborate rho t) us mt
       | LCF REC $ [(_, [x]) \ t] =>
           R.Rec (fn T => elaborate (Env.insert rho x T) t)
       | LCF (ELIM {target}) $ [_ \ m] =>
           R.Elim target (elaborateOpt m)
       | LCF (INTRO {rule}) $ [_ \ m] =>
           R.Intro rule (elaborateOpt m)
       | `x => Env.lookup rho x
       | _ => raise Fail "Expected tactic"

  (* Below, as an optimization, we implicitly calculate the modulus of
   * continuity of the lhs tactic using [THEN_LAZY] rather than doing it
   * separately as in the Definition. In this way, we can avoid executing the
   * lhs tactic twice. *)
  and elaborateMulti rho T1 us mt =
    case #1 (infer mt) of
         LCF ALL $ [_ \ t2] =>
           let
             val T2 = elaborate rho t2
           in
             fn alpha =>
               let
                 val beta = prepend us alpha
                 val (beta', modulus) = probe beta
               in
                 T.THEN_LAZY (T1 beta', fn () => T2 (bite (!modulus) beta))
               end
           end
       | LCF EACH $ [_ \ v] =>
           let
             val Ts = List.map (elaborate rho) (elaborateVec v)
           in
             fn alpha =>
               let
                 val beta = prepend us alpha
                 val (beta', modulus) = probe beta
               in
                 T.THENL_LAZY (T1 beta', fn () =>
                   List.map (fn Ti => Ti (bite (!modulus) beta)) Ts)
               end
           end
       | LCF (FOCUS i) $ [_\ t2] =>
           let
             val T2 = elaborate rho t2
           in
             fn alpha =>
               let
                 val beta = prepend us alpha
                 val (beta', modulus) = probe beta
               in
                 T.THENF_LAZY (T1 beta', i, fn () => T2 (bite (!modulus) beta))
               end
           end
       | _ => raise Fail "Expected multitactic"
end
