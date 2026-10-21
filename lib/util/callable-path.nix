{
  mk = path: fn: {
    outPath = path;
    __functor = _: fn;
  };

  isCallablePath = v:
    builtins.isAttrs v && v ? outPath && v ? __functor;
}
