let sum_of = List.fold_left (+) 0
let max_of = List.fold_left max 0

let (<<<) f g = fun x -> f (g x)
let (>>>) f g = fun x -> g (f x)
