{ fenix, src, fenixFromSubstrate }:
let
  consumerSubstrate =
    if builtins.isAttrs src && src ? inputs && src.inputs ? substrate
    then src.inputs.substrate
    else { };
in
if fenix != null then fenix
else if fenixFromSubstrate then (consumerSubstrate.inputs or { }).fenix or null
else null
