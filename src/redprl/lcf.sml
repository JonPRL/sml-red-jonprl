structure LcfLanguage = LcfAbtLanguage (RedPrlAbt)

structure Lcf :
sig
  include LCF_UTIL
  val prettyState : jdg state -> FinalPrinter.doc
end =
struct
  structure Lcf = Lcf (LcfLanguage)
  structure Def = LcfUtilPure (structure Lcf = Lcf structure J = RedPrlJudgment)
  open Def Lcf
  infix |> ||

  (* TODO: clean up all this stuff with vsep *)

  fun prettyGoal (x, jdg) =
    Fpp.seq
      [Fpp.text "Goal",
       Fpp.space 1,
       Fpp.text ".",
       Fpp.newline,
       Fpp.nest 2 (RedPrlSequent.pretty TermPrinter.ppTerm jdg),
       Fpp.hardLine]

  val prettyGoals : jdg Tl.telescope -> {doc : FinalPrinter.doc, env : J.env, idx : int} = 
    let
      open RedPrlAbt
    in
      Tl.foldl 
        (fn (x, jdg, {doc, env, idx}) =>
          let
            val x' = Metavar.named (Int.toString idx)
            val jdg' = J.subst env jdg
            val env' = Metavar.Ctx.insert env x (LcfLanguage.var x' (J.sort jdg'))
          in
            {doc = Fpp.seq [doc, prettyGoal (x, jdg), Fpp.hardLine],
             env = env',
             idx = idx + 1}
          end)
        {doc = Fpp.empty, env = Metavar.Ctx.empty, idx = 0}
    end

  fun prettyState (psi |> _) = 
    #doc (prettyGoals psi)
end
