import LookupEmbedded
namespace ZkBuild.SectionPolicy

def order (id : Nat) : Int :=
  ([0,1,2,3,4,5,7,8,9,10,12,13,11,6] : List Int).getD id 0

def expected (id field : Nat) : Int :=
  if field = 0 then (if id < 14 then 1 else 0) else if field = 1 then order id else 0

end ZkBuild.SectionPolicy
